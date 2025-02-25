class VaccinationCenter < ApplicationRecord
  include HasPhoneNumberConcern
  has_phone_number_types %i[fixed_line mobile voip premium_rate toll_free uan]
  module Kinds
    CABINET_INFIRMIER = "Cabinet infirmier"
    CABINET_MEDICAL = "Cabinet médical"
    CENTRE_VACCINATION = "Centre de vaccination"
    EHPAD = "Ehpad"
    HOPITAL = "Hôpital"
    PHARMACIE = "Pharmacie"

    ALL = [CABINET_INFIRMIER, CABINET_MEDICAL, CENTRE_VACCINATION, EHPAD, HOPITAL, PHARMACIE].freeze
  end

  include PgSearch::Model
  pg_search_scope :global_search, against: [:name, :description, :kind, :address]

  validates :name, :address, :phone_number, presence: true
  validates :lat, :lon, presence: true, on: :validation_by_admin
  validates :kind, inclusion: {in: VaccinationCenter::Kinds::ALL}
  validates :address, postal_address: {with_zipcode: true}, on: :create

  has_many :partner_vaccination_centers
  has_many :partners, through: :partner_vaccination_centers
  belongs_to :confirmer, class_name: "User", optional: true

  has_many :campaigns

  scope :confirmed, -> { where.not(confirmed_at: nil) }

  after_initialize :approximated_lat_lon
  attr_reader :approximated_lat, :approximated_lon

  after_commit :push_to_slack, on: :create
  after_commit :geocode_address, if: -> { saved_change_to_address? }

  def active?
    confirmed? && !disabled?
  end

  def disabled?
    disabled_at.present?
  end

  def confirmed?
    confirmed_at.present?
  end

  def can_be_accessed_by?(user, partner)
    return true if user&.has_role?(:admin)

    partners.include?(partner)
  end

  def geocode_address
    GeocodeResourceJob.perform_later(self)
  end

  def self.to_csv
    headers = [
      "ID",
      "Nom du centre",
      "Type de centre",
      "Description",
      "Adresse",
      "Latitude",
      "Longitude",
      "Code postal",
      "Ville",
      "Département",
      "Téléphone",
      "Type de vaccin",
      "Nom du contact",
      "Email du contact",
      "Téléphone du contact",
      "Validé",
      "Validé par",
      "Validé le"
    ]

    CSV.generate("\uFEFF", headers: true) do |csv|
      csv << headers

      all.each do |vaccination_center|
        vaccin_types = ""
        confirmed = false
        if vaccination_center.pfizer
          vaccin_types += Vaccine::Brands::PFIZER + " "
        end
        if vaccination_center.moderna
          vaccin_types += Vaccine::Brands::MODERNA + " "
        end
        if vaccination_center.astrazeneca
          vaccin_types += Vaccine::Brands::ASTRAZENECA + " "
        end
        if vaccination_center.janssen
          vaccin_types += Vaccine::Brands::JANSSEN
        end
        if vaccination_center.confirmed_at
          confirmed = true
        end
        line = [
          vaccination_center.id,
          vaccination_center.name,
          vaccination_center.kind,
          vaccination_center.description,
          vaccination_center.address,
          vaccination_center.lat,
          vaccination_center.lon,
          vaccination_center.zipcode,
          vaccination_center.city,
          vaccination_center.geo_context,
          vaccination_center.human_friendly_phone_number,
          vaccin_types,
          vaccination_center.partners&.first&.name,
          vaccination_center.partners&.first&.email,
          vaccination_center.partners&.first&.human_friendly_phone_number,
          confirmed
        ]
        if confirmed
          line += [vaccination_center.confirmer&.to_s, vaccination_center.confirmed_at].compact
        end
        csv << line
      end
    end
  end

  def flipper_id
    "#{self.class.name}_#{id}"
  end

  def build_campaign_smart_defaults
    last_campaign = campaigns.order(:created_at).last
    if last_campaign
      last_campaign_slice = last_campaign.as_json.slice("extra_info", "vaccine_type", "min_age", "max_age", "max_distance_in_meters", "available_doses")
      campaigns.build(last_campaign_slice)
    else
      campaigns.build
    end
  end

  def human_friendly_geo_area
    if zipcode && city && geo_context
      region = geo_context.split(",")[-1]
      "#{city}, #{region} (#{zipcode})"
    end
  end

  def visible_optin
    false # waiting for https://github.com/hostolab/covidliste/issues/473
  end

  def public_name
    visible_optin ? name : "Lieu de vaccination inscrit"
  end

  def public_location
    visible_optin ? address : geo_context
  end

  def public_kind
    visible_optin ? kind : nil
  end

  def public_description
    visible_optin ? kind : "La localisation est approximée à quelques kilomètres"
  end

  def public_lat
    visible_optin ? lat : approximated_lat
  end

  def public_lon
    visible_optin ? lon : approximated_lon
  end

  def map_color
    case kind
    when VaccinationCenter::Kinds::CABINET_INFIRMIER
      "#ffe733"
    when VaccinationCenter::Kinds::CABINET_MEDICAL
      "#3733ff"
    when VaccinationCenter::Kinds::CENTRE_VACCINATION
      "#ffaf33"
    when VaccinationCenter::Kinds::EHPAD
      "#bb33ff"
    when VaccinationCenter::Kinds::HOPITAL
      "#ff3333"
    when VaccinationCenter::Kinds::PHARMACIE
      "#409e1b"
    else
      "#3388ff"
    end
  end

  private

  def approximated_lat_lon
    return if lat.nil? || lon.nil?
    results = ::RandomizeCoordinatesService.new(lat, lon, 5000).call
    @approximated_lat = results[:lat]
    @approximated_lon = results[:lon]
  end

  def push_to_slack
    return unless Rails.env.production?

    # Wait for vaccination partner to be created
    PushNewVaccinationCenterToSlackJob.set(wait: 5.seconds).perform_later(id)
  end
end

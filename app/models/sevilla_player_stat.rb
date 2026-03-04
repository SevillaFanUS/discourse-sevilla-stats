# frozen_string_literal: true

class SevillaPlayerStat < ActiveRecord::Base
  validates :uid,            presence: true, uniqueness: true
  validates :player_id,      presence: true
  validates :player_name,    presence: true
  validates :season,         presence: true
  validates :competition_id, presence: true

  before_validation :assign_uid, on: :create

  # -------------------------------------------------------------------------
  # Scopes
  # -------------------------------------------------------------------------

  scope :for_season,      ->(season) { where(season: season) }
  scope :for_competition, ->(comp_id) { where(competition_id: comp_id.to_s) }
  scope :by_goals,        -> { order(goals: :desc, assists: :desc) }
  scope :by_assists,      -> { order(assists: :desc, goals: :desc) }
  scope :by_appearances,  -> { order(appearances: :desc, minutes_played: :desc) }
  scope :by_cards,        -> { order(Arel.sql("yellow_cards + red_cards DESC")) }

  # -------------------------------------------------------------------------
  # Class helpers
  # -------------------------------------------------------------------------

  # Upsert a player stat record from API data.
  # Finds by player_id + season + competition_id, creates or updates.
  def self.upsert_from_api!(player_id:, player_name:, position:, nationality:,
                             season:, competition_id:, competition_name:,
                             appearances:, minutes_played:, goals:, assists:,
                             yellow_cards:, red_cards:, last_updated:)
    record = find_or_initialize_by(
      player_id:      player_id,
      season:         season.to_s,
      competition_id: competition_id.to_s
    )

    record.assign_attributes(
      player_name:     player_name,
      position:        position,
      nationality:     nationality,
      competition_name: competition_name,
      appearances:     appearances.to_i,
      minutes_played:  minutes_played.to_i,
      goals:           goals.to_i,
      assists:         assists.to_i,
      yellow_cards:    yellow_cards.to_i,
      red_cards:       red_cards.to_i,
      last_updated:    last_updated
    )

    record.save!
    record
  end

  # Aggregate totals across all competitions for a given season
  def self.season_totals(season)
    for_season(season)
      .group(:player_id, :player_name, :position, :nationality)
      .select(
        :player_id,
        :player_name,
        :position,
        :nationality,
        "SUM(appearances)    AS total_appearances",
        "SUM(minutes_played) AS total_minutes",
        "SUM(goals)          AS total_goals",
        "SUM(assists)        AS total_assists",
        "SUM(yellow_cards)   AS total_yellow_cards",
        "SUM(red_cards)      AS total_red_cards"
      )
      .order(Arel.sql("SUM(goals) DESC, SUM(assists) DESC"))
  end

  private

  def assign_uid
    self.uid ||= SecureRandom.uuid
  end
end

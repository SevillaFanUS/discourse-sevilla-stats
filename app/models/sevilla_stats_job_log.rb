# frozen_string_literal: true

class SevillaStatsJobLog < ActiveRecord::Base
  validates :uid,            presence: true, uniqueness: true
  validates :match_id,       presence: true, uniqueness: true
  validates :competition_id, presence: true
  validates :home_team,      presence: true
  validates :away_team,      presence: true
  validates :match_date,     presence: true
  validates :processed_at,   presence: true

  before_validation :assign_uid, on: :create

  scope :recent, -> { order(processed_at: :desc) }
  scope :for_competition, ->(comp_id) { where(competition_id: comp_id.to_s) }

  def self.already_processed?(match_id)
    exists?(match_id: match_id)
  end

  def self.record_processed!(match_id:, competition_id:, competition_name:,
                              matchday:, home_team:, away_team:,
                              home_score:, away_score:, match_date:,
                              discourse_post_id: nil)
    create!(
      match_id:          match_id,
      competition_id:    competition_id.to_s,
      competition_name:  competition_name,
      matchday:          matchday,
      home_team:         home_team,
      away_team:         away_team,
      home_score:        home_score,
      away_score:        away_score,
      match_date:        match_date,
      discourse_post_id: discourse_post_id,
      processed_at:      Time.now
    )
  end

  private

  def assign_uid
    self.uid ||= SecureRandom.uuid
  end
end

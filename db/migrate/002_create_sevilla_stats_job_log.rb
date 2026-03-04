# frozen_string_literal: true

class CreateSevillaStatsJobLog < ActiveRecord::Migration[7.0]
  def up
    create_table :sevilla_stats_job_logs do |t|
      t.string   :uid,            null: false
      t.integer  :match_id,       null: false   # football-data.org match ID
      t.string   :competition_id, null: false
      t.string   :competition_name
      t.integer  :matchday
      t.string   :home_team,      null: false
      t.string   :away_team,      null: false
      t.integer  :home_score
      t.integer  :away_score
      t.datetime :match_date,     null: false
      t.integer  :discourse_post_id              # the reply post ID created
      t.datetime :processed_at,   null: false
      t.timestamps null: false
    end

    add_index :sevilla_stats_job_logs, :uid, unique: true
    add_index :sevilla_stats_job_logs, :match_id, unique: true
    add_index :sevilla_stats_job_logs, :processed_at
  end

  def down
    drop_table :sevilla_stats_job_logs
  end
end

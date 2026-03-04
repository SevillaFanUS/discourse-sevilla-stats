# frozen_string_literal: true

class CreateSevillaPlayerStats < ActiveRecord::Migration[7.0]
  def up
    create_table :sevilla_player_stats do |t|
      t.string  :uid,            null: false
      t.integer :player_id,      null: false   # football-data.org player ID
      t.string  :player_name,    null: false
      t.string  :position
      t.string  :nationality
      t.string  :season,         null: false
      t.string  :competition_id, null: false   # e.g. "2014"
      t.string  :competition_name              # e.g. "La Liga"

      # Core stats
      t.integer :appearances,    null: false, default: 0
      t.integer :minutes_played, null: false, default: 0
      t.integer :goals,          null: false, default: 0
      t.integer :assists,        null: false, default: 0
      t.integer :yellow_cards,   null: false, default: 0
      t.integer :red_cards,      null: false, default: 0

      t.datetime :last_updated,  null: false
      t.timestamps null: false
    end

    add_index :sevilla_player_stats, :uid, unique: true
    add_index :sevilla_player_stats, %i[player_id season competition_id], unique: true, name: "idx_sevilla_stats_player_season_comp"
    add_index :sevilla_player_stats, :season
    add_index :sevilla_player_stats, :player_id
  end

  def down
    drop_table :sevilla_player_stats
  end
end

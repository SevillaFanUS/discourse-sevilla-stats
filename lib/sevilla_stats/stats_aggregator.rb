# frozen_string_literal: true

module SevillaStats
  class StatsAggregator
    attr_reader :season, :client

    def initialize(api_client, season)
      @client = api_client
      @season = season.to_s
    end

    # -------------------------------------------------------------------------
    # Main entry point — fetches all stats and upserts DB records.
    # Returns a hash of newly finished matches that haven't been processed yet.
    # -------------------------------------------------------------------------
    def refresh_all_stats!
      new_matches = []

      client.competition_ids.each do |comp_id|
        Rails.logger.info("[SevillaStats] Processing competition #{comp_id}")

        # Fetch & persist player stats for this competition
        fetch_and_store_scorers!(comp_id)

        # Find unprocessed finished matches in this competition
        unprocessed = unprocessed_matches_for_competition(comp_id)
        new_matches.concat(unprocessed)
      end

      new_matches
    end

    # -------------------------------------------------------------------------
    # Fetch scorer/assist data from API and upsert into DB
    # -------------------------------------------------------------------------
    def fetch_and_store_scorers!(competition_id)
      scorers = client.top_scorers(competition_id, season)
      comp_name = client.competition_name(competition_id)

      scorers.each do |scorer|
        player = scorer["player"]
        next unless player && player["id"]

        SevillaPlayerStat.upsert_from_api!(
          player_id:        player["id"],
          player_name:      player["name"],
          position:         player["position"],
          nationality:      player["nationality"],
          season:           season,
          competition_id:   competition_id,
          competition_name: comp_name,
          appearances:      scorer["playedMatches"].to_i,
          minutes_played:   0,   # scorers endpoint doesn't return minutes; enriched separately
          goals:            scorer["goals"].to_i,
          assists:          scorer["assists"].to_i,
          yellow_cards:     0,   # enriched from match details
          red_cards:        0,
          last_updated:     Time.now
        )
      end

      Rails.logger.info("[SevillaStats] Stored #{scorers.size} scorer records for comp #{competition_id}")
    rescue => e
      Rails.logger.error("[SevillaStats] Error storing scorers for comp #{competition_id}: #{e.message}")
    end

    # -------------------------------------------------------------------------
    # Enrich player stats with minutes + cards from match lineups
    # Called for each new match detected
    # -------------------------------------------------------------------------
    def enrich_from_match!(match_id, competition_id)
      detail = client.match_detail(match_id)
      return unless detail

      comp_name = client.competition_name(competition_id)
      team_id   = SiteSetting.sevilla_stats_team_id

      # Determine which side Sevilla is on
      home_id = detail.dig("homeTeam", "id")
      away_id = detail.dig("awayTeam", "id")
      sevilla_key = home_id == team_id ? "homeTeam" : (away_id == team_id ? "awayTeam" : nil)
      return unless sevilla_key

      lineup   = detail.dig(sevilla_key, "lineup") || []
      bench    = detail.dig(sevilla_key, "bench") || []
      all_players = lineup + bench

      bookings = (detail["bookings"] || []).select do |b|
        b.dig("team", "id") == team_id
      end

      substitutions = (detail["substitutions"] || []).select do |s|
        s.dig("team", "id") == team_id
      end

      match_duration = detail.dig("score", "duration") == "EXTRA_TIME" ? 120 : 90

      all_players.each do |player|
        next unless player["id"]

        # Calculate minutes played
        minutes = calculate_minutes(
          player:        player,
          lineup:        lineup,
          substitutions: substitutions,
          match_duration: match_duration
        )

        # Count cards
        player_bookings = bookings.select { |b| b.dig("player", "id") == player["id"] }
        yellow_cards = player_bookings.count { |b| b["card"] == "YELLOW" }
        red_cards    = player_bookings.count { |b| %w[RED YELLOW_RED].include?(b["card"]) }

        # Find or create stat record and add incremental values
        stat = SevillaPlayerStat.find_or_initialize_by(
          player_id:      player["id"],
          season:         season,
          competition_id: competition_id.to_s
        )

        if stat.new_record?
          stat.assign_attributes(
            uid:              SecureRandom.uuid,
            player_name:      player["name"],
            position:         player["position"],
            nationality:      player["nationality"],
            competition_name: comp_name,
            appearances:      minutes > 0 ? 1 : 0,
            minutes_played:   minutes,
            goals:            0,
            assists:          0,
            yellow_cards:     yellow_cards,
            red_cards:        red_cards,
            last_updated:     Time.now
          )
        else
          stat.appearances    += 1 if minutes > 0
          stat.minutes_played += minutes
          stat.yellow_cards   += yellow_cards
          stat.red_cards      += red_cards
          stat.last_updated    = Time.now
        end

        stat.save!
      end
    rescue => e
      Rails.logger.error("[SevillaStats] Error enriching match #{match_id}: #{e.message}")
    end

    # -------------------------------------------------------------------------
    # Build aggregated stats for post formatting
    # -------------------------------------------------------------------------
    def aggregated_stats_for_season
      SevillaPlayerStat.for_season(season)
    end

    private

    # Find finished Sevilla matches for a competition that haven't been posted yet
    def unprocessed_matches_for_competition(competition_id)
      matches = client.sevilla_finished_matches(season)
      return [] unless matches

      matches.select do |m|
        m.dig("competition", "id").to_s == competition_id.to_s &&
          !SevillaStatsJobLog.already_processed?(m["id"])
      end
    end

    # Estimate minutes played for a player in a match
    def calculate_minutes(player:, lineup:, substitutions:, match_duration:)
      in_lineup = lineup.any? { |l| l["id"] == player["id"] }

      # Find if this player was subbed off
      subbed_off = substitutions.find { |s| s.dig("playerOut", "id") == player["id"] }
      # Find if this player was subbed on
      subbed_on  = substitutions.find { |s| s.dig("playerIn", "id") == player["id"] }

      if in_lineup
        subbed_off ? (subbed_off["minute"].to_i) : match_duration
      elsif subbed_on
        match_duration - subbed_on["minute"].to_i
      else
        0
      end
    end
  end
end

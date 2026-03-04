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
    # Returns an array of newly finished matches that haven't been processed yet.
    #
    # Strategy:
    #   1. For each finished match, enrich all players from the lineup (minutes,
    #      cards, appearances). This is the source of truth for who played.
    #   2. After lineup enrichment, overlay goals/assists from the scorers
    #      endpoint — but only update existing records, never create new ones
    #      from scorers alone (they only cover players who scored).
    # -------------------------------------------------------------------------
    def refresh_all_stats!
      new_matches = []

      client.competition_ids.each do |comp_id|
        Rails.logger.info("[SevillaStats] Fetching finished matches for competition #{comp_id}")

        all_finished = finished_matches_for_competition(comp_id)
        Rails.logger.info("[SevillaStats] Competition #{comp_id}: #{all_finished.size} total finished match(es)")

        unprocessed = all_finished.reject { |m| SevillaStatsJobLog.already_processed?(m["id"]) }
        Rails.logger.info("[SevillaStats] Competition #{comp_id}: #{unprocessed.size} unprocessed match(es)")
        unprocessed.each do |m|
          Rails.logger.info("[SevillaStats]   -> Match #{m["id"]}: #{m.dig("homeTeam","name")} vs #{m.dig("awayTeam","name")} (#{m["utcDate"]})")
        end

        new_matches.concat(unprocessed)
      end

      # Overlay goals/assists onto already-enriched records. Safe every cycle.
      client.competition_ids.each { |comp_id| overlay_goals_and_assists!(comp_id) }

      new_matches
    end

    # -------------------------------------------------------------------------
    # Enrich player stats with appearances, minutes + cards from match lineups.
    # This is the primary source of player records — everyone who played.
    # -------------------------------------------------------------------------
    def enrich_from_match!(match_id, competition_id)
      detail = client.match_detail(match_id)
      return unless detail

      comp_name = client.competition_name(competition_id)
      team_id   = SiteSetting.sevilla_stats_team_id

      # Determine which side Sevilla is on
      home_id     = detail.dig("homeTeam", "id")
      away_id     = detail.dig("awayTeam", "id")
      sevilla_key = if home_id == team_id
                      "homeTeam"
                    elsif away_id == team_id
                      "awayTeam"
                    end
      return unless sevilla_key

      lineup      = detail.dig(sevilla_key, "lineup") || []
      bench       = detail.dig(sevilla_key, "bench")  || []
      all_players = lineup + bench

      if all_players.empty?
        Rails.logger.warn("[SevillaStats] Match #{match_id} has no lineup data yet — skipping enrichment")
        return
      end

      bookings = (detail["bookings"] || []).select { |b| b.dig("team", "id") == team_id }
      substitutions = (detail["substitutions"] || []).select { |s| s.dig("team", "id") == team_id }
      match_duration = detail.dig("score", "duration") == "EXTRA_TIME" ? 120 : 90

      all_players.each do |player|
        next unless player["id"]

        minutes      = calculate_minutes(player: player, lineup: lineup,
                                         substitutions: substitutions,
                                         match_duration: match_duration)
        player_cards = bookings.select { |b| b.dig("player", "id") == player["id"] }
        yellow_cards = player_cards.count { |b| b["card"] == "YELLOW" }
        red_cards    = player_cards.count { |b| %w[RED YELLOW_RED].include?(b["card"]) }

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

      Rails.logger.info("[SevillaStats] Enriched #{all_players.size} players from match #{match_id}")
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

    # -------------------------------------------------------------------------
    # Overlay goals and assists from the scorers endpoint onto existing records.
    # Never creates new records — only updates players already in the DB from
    # lineup enrichment. This avoids the scorers endpoint's bias toward players
    # who scored (which would exclude defenders, keepers, etc.).
    # -------------------------------------------------------------------------
    def overlay_goals_and_assists!(competition_id)
      scorers = client.top_scorers(competition_id, season)
      return if scorers.empty?

      updated = 0
      scorers.each do |scorer|
        player = scorer["player"]
        next unless player && player["id"]

        # Only update if a record already exists (created by lineup enrichment)
        stat = SevillaPlayerStat.find_by(
          player_id:      player["id"],
          season:         season,
          competition_id: competition_id.to_s
        )
        next unless stat

        stat.update!(
          goals:        scorer["goals"].to_i,
          assists:      scorer["assists"].to_i,
          last_updated: Time.now
        )
        updated += 1
      end

      Rails.logger.info("[SevillaStats] Overlaid goals/assists for #{updated} players in comp #{competition_id}")
    rescue => e
      Rails.logger.error("[SevillaStats] Error overlaying goals for comp #{competition_id}: #{e.message}")
    end

    # All finished Sevilla matches for a given competition this season
    def finished_matches_for_competition(competition_id)
      matches = client.sevilla_finished_matches(season)
      return [] unless matches

      matches.select { |m| m.dig("competition", "id").to_s == competition_id.to_s }
    end

    # Estimate minutes played for a player in a match
    def calculate_minutes(player:, lineup:, substitutions:, match_duration:)
      in_lineup  = lineup.any? { |l| l["id"] == player["id"] }
      subbed_off = substitutions.find { |s| s.dig("playerOut", "id") == player["id"] }
      subbed_on  = substitutions.find { |s| s.dig("playerIn", "id") == player["id"] }

      if in_lineup
        subbed_off ? subbed_off["minute"].to_i : match_duration
      elsif subbed_on
        match_duration - subbed_on["minute"].to_i
      else
        0
      end
    end
  end
end

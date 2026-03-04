# frozen_string_literal: true

module SevillaStats
  class PostFormatter
    SEVILLA_CREST = "https://crests.football-data.org/559.png"

    COMPETITION_LABELS = {
      "2014" => "La Liga",
      "2079" => "Copa del Rey",
      "2146" => "UEFA Europa League",
      "2001" => "UEFA Champions League",
      "2154" => "UEFA Conference League"
    }.freeze

    POSITION_ORDER = %w[Goalkeeper Defender Midfielder Forward Attacker].freeze

    # -------------------------------------------------------------------------
    # Build the initial pinned topic body (created on first run)
    # emblems: hash of { competition_id => url_or_nil } from ApiClient#competition_emblems
    # -------------------------------------------------------------------------
    def self.initial_topic_body(season, emblems = {})
      year_start = season.to_i
      year_end   = year_start + 1
      year_short = "#{(year_start % 100).to_s.rjust(2, "0")}/#{(year_end % 100).to_s.rjust(2, "0")}"

      comp_rows = emblems.map do |comp_id, emblem_url|
        label       = COMPETITION_LABELS[comp_id.to_s] || "Competition #{comp_id}"
        # Only render image if URL verified; shrink to max 60px height
        emblem_cell = emblem_url ? "<img src=\"#{emblem_url}\" height=\"60\" alt=\"#{label}\">" : "—"
        "| #{label} | #{emblem_cell} |"
      end.join("\n")

      body = <<~MD
        # :bar_chart: Sevilla FC — #{year_start}/#{year_end} Season Statistics

        ![Sevilla FC](#{SEVILLA_CREST})

        Welcome to the **official season stats thread** for Sevilla FC's #{year_start}/#{year_end} campaign.

        This thread is automatically updated after every match across all competitions.
        Each reply below contains a full stats update for that matchday.

        ---

        ## :clipboard: How to Read This Thread

        - **This post** is the index — scroll down for individual matchday updates
        - Stats cover all competitions Sevilla are active in this season
        - Player stats are aggregated across all competitions in the summary

        ---

        ## :trophy: Competitions This Season — #{year_short}

        | Competition | Emblem |
        |-------------|--------|
        COMP_ROWS_PLACEHOLDER

        ---

        *First stats update will appear as a reply below after the next completed match.*

        *Last generated: #{Time.now.strftime("%d %B %Y")}*
      MD

      body.sub("COMP_ROWS_PLACEHOLDER", comp_rows)
    end

    # -------------------------------------------------------------------------
    # Build a matchday update reply post
    # match_info: hash with match details
    # season:     string e.g. "2025"
    # standings:  array of standing rows (optional, for La Liga)
    # emblems:    hash of { competition_id => url_or_nil } from ApiClient#competition_emblems
    # -------------------------------------------------------------------------
    def self.matchday_update(match_info:, season:, standings: [], emblems: {})
      competition_id   = match_info[:competition_id].to_s
      competition_name = COMPETITION_LABELS[competition_id] || match_info[:competition_name]
      comp_emblem      = emblems[competition_id]
      matchday_label   = match_info[:matchday] ? "Matchday #{match_info[:matchday]}" : "Match"

      year_start = season.to_i
      year_end   = year_start + 1

      home = match_info[:home_team]
      away = match_info[:away_team]
      hs   = match_info[:home_score]
      as_  = match_info[:away_score]
      result_emoji = sevilla_result_emoji(home, away, hs, as_)

      lines = []
      lines << "---"
      lines << ""

      # Header — emblem rendered at 60px height if verified, plain text otherwise
      if comp_emblem
        lines << "## #{result_emoji} #{matchday_label} Update | <img src=\"#{comp_emblem}\" height=\"60\" alt=\"#{competition_name}\"> #{competition_name}"
      else
        lines << "## #{result_emoji} #{matchday_label} Update | #{competition_name}"
      end

      lines << ""
      lines << "> **#{home} #{hs}–#{as_} #{away}** | #{match_info[:match_date]&.strftime("%d %B %Y")}"
      lines << ""

      lines << "### :bar_chart: Season Totals — #{year_start}/#{year_end} (All Competitions)"
      lines << ""

      lines << build_goals_assists_table(season)
      lines << ""

      lines << build_appearances_table(season)
      lines << ""

      lines << build_discipline_table(season)
      lines << ""

      lines << "### :clipboard: By Competition"
      lines << ""

      competition_ids_with_data(season).each do |comp_id|
        comp_label      = COMPETITION_LABELS[comp_id] || comp_id
        comp_emblem_url = emblems[comp_id]

        # Only render emblem image if URL was verified (not nil), at 60px height
        header = if comp_emblem_url
          "#### <img src=\"#{comp_emblem_url}\" height=\"60\" alt=\"#{comp_label}\"> #{comp_label}"
        else
          "#### #{comp_label}"
        end
        lines << header
        lines << ""
        lines << build_competition_table(season, comp_id)
        lines << ""
      end

      # La Liga standings — always current table (API limitation noted inline)
      if competition_id == "2014" && standings.any?
        lines << "### :trophy: La Liga Standings (Current Table)"
        lines << ""
        lines << "_Note: The API only provides the current live standings, not the table as it was on this matchday._"
        lines << ""
        lines << build_standings_table(standings)
        lines << ""
      end

      lines << "*Stats updated: #{Time.now.strftime("%d %B %Y %H:%M")} UTC*"
      lines << ""

      lines.join("\n")
    end

    # =========================================================================
    private
    # =========================================================================

    def self.sevilla_result_emoji(home_team, away_team, home_score, away_score)
      sevilla_home  = home_team.to_s.downcase.include?("sevilla")
      sevilla_score = sevilla_home ? home_score.to_i : away_score.to_i
      opp_score     = sevilla_home ? away_score.to_i : home_score.to_i

      if sevilla_score > opp_score
        ":white_check_mark:"
      elsif sevilla_score == opp_score
        ":handshake:"
      else
        ":x:"
      end
    end

    def self.build_goals_assists_table(season)
      # All players — including those with zero goals/assists
      rows = SevillaPlayerStat
               .season_totals(season)
               .reorder(Arel.sql("SUM(goals) DESC, SUM(assists) DESC, SUM(appearances) DESC"))

      return "_No player data yet._" if rows.empty?

      lines = []
      lines << "**:goal_net: Goals & Assists**"
      lines << ""
      lines << "| # | Player | Position | Goals | Assists | Matches |"
      lines << "|---|--------|----------|------:|--------:|--------:|"

      rows.each_with_index do |r, i|
        goals_str = r.total_goals > 0 ? "**#{r.total_goals}**" : r.total_goals.to_s
        lines << "| #{i + 1} | #{r.player_name} | #{r.position || "—"} | #{goals_str} | #{r.total_assists} | #{r.total_appearances} |"
      end

      lines.join("\n")
    end

    def self.build_appearances_table(season)
      # All players with at least one appearance — no limit
      rows = SevillaPlayerStat
               .season_totals(season)
               .having("SUM(appearances) > 0")
               .reorder(Arel.sql("SUM(appearances) DESC, SUM(minutes_played) DESC"))

      return "_No appearances data yet._" if rows.empty?

      lines = []
      lines << "**:shirt: Appearances & Minutes**"
      lines << ""
      lines << "| Player | Position | Apps | Minutes |"
      lines << "|--------|----------|-----:|--------:|"

      rows.each do |r|
        lines << "| #{r.player_name} | #{r.position || "—"} | #{r.total_appearances} | #{r.total_minutes} |"
      end

      lines.join("\n")
    end

    def self.build_discipline_table(season)
      rows = SevillaPlayerStat
               .season_totals(season)
               .having("SUM(yellow_cards) > 0 OR SUM(red_cards) > 0")
               .reorder(Arel.sql("SUM(yellow_cards + red_cards) DESC"))

      return "_No discipline data yet._" if rows.empty?

      lines = []
      lines << "**:yellow_square: Discipline**"
      lines << ""
      lines << "| Player | :yellow_square: Yellow | :red_square: Red |"
      lines << "|--------|----------------------:|----------------:|"

      rows.each do |r|
        lines << "| #{r.player_name} | #{r.total_yellow_cards} | #{r.total_red_cards} |"
      end

      lines.join("\n")
    end

    def self.build_competition_table(season, competition_id)
      # All players with any activity in this competition — no limit
      rows = SevillaPlayerStat
               .for_season(season)
               .for_competition(competition_id)
               .where("appearances > 0")
               .order(goals: :desc, assists: :desc, appearances: :desc)

      return "_No data for this competition yet._" if rows.empty?

      lines = []
      lines << "| Player | Apps | Mins | Goals | Assists | :yellow_square: | :red_square: |"
      lines << "|--------|-----:|-----:|------:|--------:|:--------------:|:------------:|"

      rows.each do |r|
        lines << "| #{r.player_name} | #{r.appearances} | #{r.minutes_played} | #{r.goals} | #{r.assists} | #{r.yellow_cards} | #{r.red_cards} |"
      end

      lines.join("\n")
    end

    def self.build_standings_table(standings)
      lines = []
      lines << "| Pos | Club | P | W | D | L | GF | GA | GD | Pts |"
      lines << "|----:|-----|--:|--:|--:|--:|---:|---:|---:|----:|"

      standings.first(10).each do |row|
        team_name  = row.dig("team", "name") || "Unknown"
        is_sevilla = team_name.downcase.include?("sevilla")
        b          = is_sevilla ? "**" : ""

        lines << "| #{b}#{row["position"]}#{b} | #{b}#{team_name}#{b} | #{row["playedGames"]} | #{row["won"]} | #{row["draw"]} | #{row["lost"]} | #{row["goalsFor"]} | #{row["goalsAgainst"]} | #{row["goalDifference"]} | #{b}#{row["points"]}#{b} |"
      end

      lines.join("\n")
    end

    def self.competition_ids_with_data(season)
      SevillaPlayerStat
        .for_season(season)
        .distinct
        .pluck(:competition_id)
        .sort
    end
  end
end

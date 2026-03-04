# discourse-sevilla-stats

A Discourse plugin for **MonchisMen.com** that automatically tracks and posts Sevilla FC season statistics after every match.

## Features

- **Auto-creates** a pinned "Sevilla FC 2025/2026 Season Stats" topic on first run
- **Posts a new reply** after every completed match with full stats tables
- Covers **La Liga, Copa del Rey, and European competition** (configurable)
- Tracks per-player: Goals, Assists, Appearances, Minutes Played, Yellow/Red Cards
- Shows season totals aggregated across all competitions
- Shows per-competition breakdown
- Shows La Liga standings after each league match
- Uses `sevilla_player_stats` DB table with UUID column for clean data management

---

## Installation

1. Copy the `discourse-sevilla-stats` folder into your Discourse `plugins/` directory:
   ```
   /var/discourse/plugins/discourse-sevilla-stats/
   ```

2. Rebuild the container:
   ```bash
   cd /var/discourse
   ./launcher rebuild app
   ```

---

## Configuration

Go to **Admin → Settings → Plugins** and search for `sevilla_stats`:

| Setting | Description | Default |
|---|---|---|
| `sevilla_stats_enabled` | Enable/disable the plugin | `true` |
| `sevilla_stats_api_key` | Your football-data.org API key | _(required)_ |
| `sevilla_stats_season` | Season year (start year) | `2025` |
| `sevilla_stats_team_id` | Sevilla FC team ID on football-data.org | `559` |
| `sevilla_stats_competition_ids` | Comma-separated competition IDs | `2014,2015,2018` |
| `sevilla_stats_category_id` | Discourse category ID for the stats topic | `1` |
| `sevilla_stats_topic_id` | Auto-populated once topic is created | `0` |
| `sevilla_stats_topic_tag` | Tag to apply to the stats topic | `season-stats` |
| `sevilla_stats_check_interval` | How often to check for new results (minutes) | `180` |

### Competition IDs (football-data.org)

| ID | Competition |
|---|---|
| `2014` | La Liga |
| `2015` | Copa del Rey |
| `2018` | UEFA Europa League |
| `2001` | UEFA Champions League |

---

## How It Works

1. A **Sidekiq scheduled job** (`Jobs::UpdateSevillaStats`) runs every 3 hours
2. It calls the football-data.org API for finished Sevilla matches
3. New matches (not yet in `sevilla_stats_job_logs`) trigger a full stats refresh
4. Player stats are upserted into the `sevilla_player_stats` table
5. Match lineup data enriches stats with minutes played and card counts
6. A **new reply** is posted to the Season Stats topic with formatted markdown tables
7. The match is recorded in `sevilla_stats_job_logs` to prevent duplicate posts

---

## Manual Refresh

Trigger an immediate stats refresh from the admin panel:

```
POST /admin/plugins/sevilla-stats/refresh
```

Or via Rails console:
```ruby
Jobs.enqueue(:update_sevilla_stats)
```

---

## Database Tables

### `sevilla_player_stats`
Stores per-player, per-competition, per-season stats.
- UUID column (`uid`) as unique identifier (separate from PK)
- Upserted from API data after each match

### `sevilla_stats_job_logs`
Tracks which matches have already been processed.
- UUID column (`uid`) as unique identifier
- Prevents duplicate posts for the same match

---

## Related Plugin

This plugin is a companion to **discourse-sevilla-fixtures**, which creates match preview threads and calendar events.

---

## Troubleshooting

Check logs for `[SevillaStats]` entries:
```bash
./launcher logs app | grep SevillaStats
```

Common issues:
- **API key invalid** — check `sevilla_stats_api_key` setting
- **Category not found** — verify `sevilla_stats_category_id` matches an existing category
- **No matches showing** — confirm `sevilla_stats_competition_ids` includes the right IDs for current-season competitions

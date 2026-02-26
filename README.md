# DR.dk TV Guide Scraper

A Ruby-based CLI scraper that extracts the daily TV program schedule from:

https://www.dr.dk/drtv/tv-guide

Instead of parsing HTML, this scraper directly calls the same CDN API used by the DR website.

---

## Features

- Uses DR’s internal Massive/Accedo schedule API
- No HTML parsing
- No headless browser required
- No external gems required
- Clean OOP architecture
- Console + JSON + CSV export
- Safe error handling
- Single-file implementation

---

## How It Works

The DR TV Guide is a dynamic web application. When opened in a browser, it fetches schedule data from:

https://prod95-cdn.dr-massive.com/api/schedules

This scraper mimics that request by:

1. Building a browser-like HTTP request
2. Sending required headers (User-Agent, Origin, Referer)
3. Parsing the returned JSON
4. Converting broadcasts into Ruby `Program` objects
5. Exporting results to console, JSON, and CSV

---

## Project Structure
dr_tv_scraper/
bin/run-  runnable script
├── dr_tv_scraper.rb # Main script (single-file solution)
├── Gemfile # Optional (not required)
├── README.md # Documentation
├── dr_tv_schedule_2026-02-26.json
├── dr_tv_schedule_2026-02-26.csv

---

## Architecture

| Class | Responsibility |
|--------|---------------|
| `Program` | Immutable value object representing a broadcast |
| `DRApiClient` | Builds API URL and performs HTTP request |
| `DRChannelRegistry` | Resolves numeric channel IDs → display names |
| `DRTVScheduleParser` | Converts raw API JSON → `Program` objects |
| `DRTVScraper` | Orchestrates scraping and exporting |

---

## Supported Channels

The scraper supports major DR linear channels:

- DR1  
- DR2  
- DR3  
- DR Ramasjang  
- DR Ultra  
- DR K  
- DR Nyheder  
- DR Ramaskrig  
- DR1 HD  

Channel names are automatically resolved using API data or fallback mapping.

---

## Requirements

- Ruby ≥ 3.0
- macOS / Linux / Windows

Check your Ruby version:

```bash
ruby --version


Installation
git clone <repo-url>
cd dr_tv_scraper

No additional gems required.

Optional:

gem install bundler
bundle install
Usage
Scrape today’s schedule
ruby dr_tv_scraper.rb


ruby dr_tv_scraper.rb 2026-02-26

or bin/run for todays date
and bin/run date. (bin/run 2026-02-27 )
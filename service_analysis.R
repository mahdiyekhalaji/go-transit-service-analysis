# ============================================================
# GO Transit Service-Level & Headway Analysis
# Data: Metrolinx GO-GTFS open data feed (2026-08-07 to 2026-09-04)
# Author: Maddie
# ============================================================

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})

gtfs_dir <- "~/go-transit-project/data/gtfs"
out_dir  <- "~/go-transit-project/outputs"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---- 1. Load GTFS tables ------------------------------------
routes     <- fread(file.path(gtfs_dir, "routes.txt"))
trips      <- fread(file.path(gtfs_dir, "trips.txt"))
stop_times <- fread(file.path(gtfs_dir, "stop_times.txt"))
stops      <- fread(file.path(gtfs_dir, "stops.txt"))
cal_dates  <- fread(file.path(gtfs_dir, "calendar_dates.txt"), colClasses = list(character = "service_id"))

setnames(routes, names(routes), sub("^﻿", "", names(routes)))
setnames(stop_times, names(stop_times), sub("^﻿", "", names(stop_times)))
setnames(trips, names(trips), sub("^﻿", "", names(trips)))
setnames(stops, names(stops), sub("^﻿", "", names(stops)))
setnames(cal_dates, names(cal_dates), sub("^﻿", "", names(cal_dates)))

# ---- 2. Keep rail only (route_type 2 = heavy rail) ----------
rail_routes <- routes[route_type == 2, .(route_id, line = route_long_name)]
rail_trips  <- merge(trips, rail_routes, by = "route_id")

# Each service_id in this feed is a single calendar date (YYYYMMDD)
rail_trips[, date := as.IDate(as.character(service_id), format = "%Y%m%d")]
rail_trips[, dow  := weekdays(date)]
rail_trips[, day_type := fifelse(dow == "Saturday", "Saturday",
                          fifelse(dow == "Sunday", "Sunday", "Weekday"))]

# ---- 3. Trips per day per line ------------------------------
trips_per_day <- rail_trips[, .(trips = .N), by = .(date, dow, day_type, line)]
setorder(trips_per_day, date, line)
fwrite(trips_per_day, file.path(out_dir, "trips_per_day_by_line.csv"))

# Average daily trips by day type (service levels summary)
service_levels <- dcast(
  trips_per_day[, .(avg_trips = round(mean(trips), 1)), by = .(line, day_type)],
  line ~ day_type, value.var = "avg_trips"
)
setorder(service_levels, -Weekday)
fwrite(service_levels, file.path(out_dir, "service_levels_by_daytype.csv"))

# ---- 4. Union Station departures & headways -----------------
# Representative days: Wed 2026-08-19 (weekday), Sat 2026-08-15, Sun 2026-08-16
rep_days <- data.table(
  date = as.IDate(c("2026-08-19", "2026-08-15", "2026-08-16")),
  day_label = c("Weekday", "Saturday", "Sunday")
)

# GTFS times can exceed 24:00 for after-midnight trips
hms_to_min <- function(x) {
  p <- tstrsplit(x, ":", type.convert = TRUE)
  p[[1]] * 60 + p[[2]]
}

trip_last_seq <- stop_times[, .(last_seq = max(stop_sequence)), by = trip_id]
un_times <- merge(
  stop_times[stop_id == "UN",
             .(trip_id, departure_time, stop_sequence, pickup_type)],
  rail_trips[, .(trip_id, line, direction_id, date, day_type)],
  by = "trip_id"
)
un_times <- merge(un_times, trip_last_seq, by = "trip_id")
# True outbound departures only: train continues past Union
# (drops inbound trips that terminate at Union)
un_dep <- un_times[pickup_type == 0 & stop_sequence < last_seq]
un_dep[, dep_min := hms_to_min(departure_time)]
un_dep[, hour := floor(dep_min / 60)]

# Time periods (standard planning conventions)
un_dep[, period := cut(dep_min,
  breaks = c(0, 6*60, 9*60, 15*60, 19*60, Inf),
  labels = c("Early (before 06:00)", "AM peak (06:00-09:00)",
             "Midday (09:00-15:00)", "PM peak (15:00-19:00)",
             "Evening (after 19:00)"),
  right = FALSE)]

un_rep <- merge(un_dep, rep_days, by = "date")

# Departures from Union by line / period / day
dep_counts <- dcast(un_rep[, .N, by = .(day_label, line, period)],
                    line + period ~ day_label, value.var = "N", fill = 0)
fwrite(dep_counts, file.path(out_dir, "union_departures_by_period.csv"))

# Headways: gap between consecutive outbound departures per line
setorder(un_rep, day_label, line, dep_min)
un_rep[, headway := dep_min - shift(dep_min), by = .(day_label, line)]

headways <- un_rep[!is.na(headway) & !is.na(period),
  .(departures = .N + 1,
    mean_headway_min   = round(mean(headway), 0),
    median_headway_min = round(median(headway), 0),
    max_gap_min        = max(headway)),
  by = .(day_label, line, period)]
setorder(headways, day_label, line, period)
fwrite(headways, file.path(out_dir, "union_headways_by_period.csv"))

# ---- 5. Span of service at Union (weekday) ------------------
span <- un_rep[day_label == "Weekday",
  .(first_departure = departure_time[which.min(dep_min)],
    last_departure  = departure_time[which.max(dep_min)],
    total_departures = .N),
  by = line]
setorder(span, line)
fwrite(span, file.path(out_dir, "union_service_span_weekday.csv"))

# ---- 6. Charts ----------------------------------------------
line_cols <- c("Lakeshore West" = "#98002e", "Lakeshore East" = "#ff0d00",
               "Kitchener" = "#00853e", "Barrie" = "#003767",
               "Milton" = "#f57f25", "Stouffville" = "#794500",
               "Richmond Hill" = "#0099c7")

# Chart 1: average daily train trips by line and day type
p1_dat <- trips_per_day[, .(avg = mean(trips)), by = .(line, day_type)]
p1_dat[, day_type := factor(day_type, levels = c("Weekday", "Saturday", "Sunday"))]
p1 <- ggplot(p1_dat, aes(x = reorder(line, -avg), y = avg, fill = line)) +
  geom_col(show.legend = FALSE) +
  geom_text(aes(label = round(avg)), vjust = -0.4, size = 3) +
  facet_wrap(~day_type) +
  scale_fill_manual(values = line_cols) +
  labs(title = "GO Train Service Levels by Line",
       subtitle = "Average scheduled train trips per day (GTFS feed, Aug 7 - Sep 4, 2026)",
       x = NULL, y = "Train trips per day") +
  theme_minimal(base_size = 11) +
  theme(axis.text.x = element_text(angle = 40, hjust = 1))
ggsave(file.path(out_dir, "chart1_trips_by_line_daytype.png"), p1,
       width = 11, height = 5.5, dpi = 150, bg = "white")

# Chart 2: weekday departures from Union by hour (service profile)
p2_dat <- un_rep[day_label == "Weekday", .N, by = .(line, hour)]
p2 <- ggplot(p2_dat, aes(x = hour, y = N, fill = line)) +
  geom_col() +
  scale_fill_manual(values = line_cols) +
  scale_x_continuous(breaks = seq(4, 28, 2),
                     labels = function(h) sprintf("%02d:00", h %% 24)) +
  labs(title = "Weekday Train Departures from Union Station by Hour",
       subtitle = "Wednesday 2026-08-19 schedule - all GO rail lines",
       x = "Departure hour", y = "Departures", fill = "Line") +
  theme_minimal(base_size = 11)
ggsave(file.path(out_dir, "chart2_union_departures_by_hour.png"), p2,
       width = 11, height = 5.5, dpi = 150, bg = "white")

# Chart 3: median headway heatmap (weekday, by line and period)
p3_dat <- headways[day_label == "Weekday" & period != "Early (before 06:00)"]
p3 <- ggplot(p3_dat, aes(x = period, y = reorder(line, -median_headway_min),
                         fill = median_headway_min)) +
  geom_tile(color = "white", linewidth = 1) +
  geom_text(aes(label = paste0(median_headway_min, " min")), size = 3.2) +
  scale_fill_gradient(low = "#2e7d32", high = "#c62828") +
  labs(title = "Median Headway Between Union Departures (Weekday)",
       subtitle = "Minutes between consecutive outbound trains, by line and time period",
       x = NULL, y = NULL, fill = "Minutes") +
  theme_minimal(base_size = 11) +
  theme(axis.text.x = element_text(angle = 20, hjust = 1))
ggsave(file.path(out_dir, "chart3_headway_heatmap_weekday.png"), p3,
       width = 10, height = 5, dpi = 150, bg = "white")

cat("=== Service levels (avg trips/day) ===\n")
print(service_levels)
cat("\n=== Weekday span of service at Union ===\n")
print(span)
cat("\n=== Weekday headways at Union (median minutes) ===\n")
print(dcast(headways[day_label == "Weekday"], line ~ period, value.var = "median_headway_min"))
cat("\nOutputs written to", out_dir, "\n")

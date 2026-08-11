# ============================================================
# GO Transit Schedule Change Comparison
# Before: Wed 2026-08-12   After: Wed 2026-09-02
# The GO timetable change effective late August 2026 added
# weekday service on the Lakeshore corridor. This script
# quantifies exactly what changed.
# ============================================================

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})

gtfs_dir <- "~/go-transit-project/data/gtfs"
out_dir  <- "~/go-transit-project/outputs"

routes     <- fread(file.path(gtfs_dir, "routes.txt"))
trips      <- fread(file.path(gtfs_dir, "trips.txt"))
stop_times <- fread(file.path(gtfs_dir, "stop_times.txt"))
for (dt in list(routes, trips, stop_times))
  setnames(dt, names(dt), sub("^﻿", "", names(dt)))

rail_routes <- routes[route_type == 2, .(route_id, line = route_long_name)]
rail_trips  <- merge(trips, rail_routes, by = "route_id")

BEFORE <- "20260812"; AFTER <- "20260902"
cmp_trips <- rail_trips[service_id %in% c(BEFORE, AFTER)]
cmp_trips[, phase := fifelse(service_id == BEFORE, "Before (Aug 12)", "After (Sep 2)")]

# ---- 1. Trips per line, before vs after ---------------------
by_line <- dcast(cmp_trips[, .N, by = .(line, phase)], line ~ phase, value.var = "N", fill = 0)
setnames(by_line, c("line", "after", "before"))
by_line <- by_line[, .(line, before, after, change = after - before)]
setorder(by_line, -change)
fwrite(by_line, file.path(out_dir, "change_trips_by_line.csv"))

# ---- 2. Union outbound departures, before vs after ----------
hms_to_min <- function(x) { p <- tstrsplit(x, ":", type.convert = TRUE); p[[1]]*60 + p[[2]] }
trip_last_seq <- stop_times[, .(last_seq = max(stop_sequence)), by = trip_id]
un <- merge(stop_times[stop_id == "UN", .(trip_id, departure_time, stop_sequence, pickup_type)],
            cmp_trips[, .(trip_id, line, phase)], by = "trip_id")
un <- merge(un, trip_last_seq, by = "trip_id")
un <- un[pickup_type == 0 & stop_sequence < last_seq]
un[, dep_min := hms_to_min(departure_time)]
un[, hour := floor(dep_min / 60)]

dep_line <- dcast(un[, .N, by = .(line, phase)], line ~ phase, value.var = "N", fill = 0)
setnames(dep_line, c("line", "after", "before"))
dep_line[, change := after - before]
setorder(dep_line, -change)
fwrite(dep_line, file.path(out_dir, "change_union_departures_by_line.csv"))

# ---- 3. Exactly which departures were added (Lakeshore) -----
added <- list()
for (ln in c("Lakeshore West", "Lakeshore East")) {
  b <- sort(un[line == ln & phase == "Before (Aug 12)", departure_time])
  a <- sort(un[line == ln & phase == "After (Sep 2)",  departure_time])
  added[[ln]] <- setdiff(a, b)
}
added_dt <- rbindlist(lapply(names(added), function(n)
  data.table(line = n, new_departure = added[[n]])))
fwrite(added_dt, file.path(out_dir, "change_new_union_departures.csv"))

# ---- 4. Midday headway improvement on Lakeshore -------------
un[, period := cut(dep_min, breaks = c(0, 360, 540, 900, 1140, Inf),
  labels = c("Early","AM peak","Midday","PM peak","Evening"), right = FALSE)]
setorder(un, phase, line, dep_min)
un[, headway := dep_min - shift(dep_min), by = .(phase, line)]
hw <- dcast(un[!is.na(headway) & !is.na(period) & line %chin% c("Lakeshore West","Lakeshore East"),
  .(median_hw = as.numeric(median(headway))), by = .(line, period, phase)],
  line + period ~ phase, value.var = "median_hw")
fwrite(hw, file.path(out_dir, "change_lakeshore_headways.csv"))

# ---- 5. Chart: before vs after departures by hour -----------
# Emphasis form: 'before' recedes in gray, 'after' carries the line color.
p_dat <- un[line %chin% c("Lakeshore West","Lakeshore East"), .N, by = .(line, phase, hour)]
p_dat[, phase := factor(phase, levels = c("Before (Aug 12)", "After (Sep 2)"))]
cols <- c("Lakeshore West" = "#98002e", "Lakeshore East" = "#ff0d00")

p <- ggplot() +
  geom_col(data = p_dat[phase == "Before (Aug 12)"],
           aes(x = hour - 0.21, y = N), width = 0.38, fill = "#c3c2b7") +
  geom_col(data = p_dat[phase == "After (Sep 2)"],
           aes(x = hour + 0.21, y = N, fill = line), width = 0.38, show.legend = FALSE) +
  facet_wrap(~line, ncol = 1) +
  scale_fill_manual(values = cols) +
  scale_x_continuous(breaks = seq(6, 24, 2), labels = function(h) sprintf("%02d:00", h %% 24)) +
  scale_y_continuous(breaks = seq(0, 8, 2)) +
  labs(title = "Lakeshore Corridor Service Increase, Late August 2026",
       subtitle = "Outbound weekday departures from Union by hour - gray: before (Aug 12), colored: after (Sep 2)",
       x = "Departure hour", y = "Departures") +
  theme_minimal(base_size = 11)
ggsave(file.path(out_dir, "chart4_schedule_change_lakeshore.png"), p,
       width = 11, height = 6.5, dpi = 150, bg = "white")

cat("=== Trips per line, before vs after ===\n"); print(by_line)
cat("\n=== Union outbound departures ===\n"); print(dep_line)
cat("\n=== New Union departures (Lakeshore) ===\n"); print(added_dt)
cat("\n=== Lakeshore median headways by period ===\n"); print(hw)

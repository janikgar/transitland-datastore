class GTFSGraph

  CHANGE_PAYLOAD_MAX_ENTITIES = 1_000
  STOP_TIMES_MAX_LOAD = 100_000

  def initialize(filename, feed=nil)
    # GTFS Graph / TransitLand wrapper
    @feed = feed
    @gtfs = GTFS::Source.build(filename, {strict: false})
    @log = []
    # GTFS entity to Transitland entity
    @gtfs_tl = {}
    # TL Indexed by Onestop ID
    @tl_by_onestop_id = {}
  end

  def load_tl
    log "Load GTFS"
    @gtfs.load_graph
    log "Load TL"
    self.load_tl_stops
    self.load_tl_routes
    self.load_tl_operators
  end

  def load_tl_stops
    # Merge child stations into parents.
    log "  merge stations"
    stations = Hash.new { |h,k| h[k] = [] }
    @gtfs.stops.each do |stop|
      stations[@gtfs.stop(stop.parent_station) || stop] << stop
    end
    # Merge station/platforms with Stops.
    log "  stops"
    stations.each do |station,platforms|
      # Temp stop to get geometry and name.
      stop = Stop.from_gtfs(station)
      # Search by similarity
      stop, score = Stop.find_by_similarity(stop[:geometry], stop.name, radius=1000, threshold=0.6)
      # ... or create stop from GTFS
      stop ||= Stop.from_gtfs(station)
      # ... check if Stop exists, or another local Stop, or new.
      stop = Stop.find_by(onestop_id: stop.onestop_id) || @tl_by_onestop_id[stop.onestop_id] || stop
      # Add identifiers and references
      ([station]+platforms).each do |e|
        stop.add_identifier(feed_onestop_id:@feed.onestop_id, entity_id:e.id)
        @gtfs_tl[e] = stop
      end
      # Cache stop
      @tl_by_onestop_id[stop.onestop_id] = stop
      if score
        log "    #{stop.onestop_id}: #{stop.name} (search: #{station.name} = #{'%0.2f'%score.to_f})"
      else
        log "    #{stop.onestop_id}: #{stop.name}"
      end
    end
  end

  def load_tl_routes
    # Routes
    log "  routes"
    @gtfs.routes.each do |entity|
      # Find: (child gtfs trips) to (child gtfs stops) to (tl stops)
      stops = @gtfs.children(entity)
        .map { |trip| @gtfs.children(trip) }
        .reduce(Set.new, :+)
        .map { |stop| @gtfs_tl[stop] }
        .to_set
      # Skip Route if no Stops
      next if stops.empty?
      # Find uniq shape_ids of trip_ids, filter missing shapes, build geometry.
      geometry = Route::GEOFACTORY.multi_line_string(
        @gtfs
          .children(entity)
          .map(&:shape_id)
          .uniq
          .compact
          .map { |shape_id| @gtfs.shape_line(shape_id) }
          .map { |coords| Route::GEOFACTORY.line_string( coords.map { |lon, lat| Route::GEOFACTORY.point(lon, lat) } ) }
      )
      # Search by similarity
      # ... or create route from GTFS
      route = Route.from_gtfs(entity, stops)
      # ... check if Route exists, or another local Route, or new.
      route = Route.find_by(onestop_id: route.onestop_id) || @tl_by_onestop_id[route.onestop_id] || route
      # Set geometry
      route[:geometry] = geometry
      # Add references and identifiers
      route.serves ||= Set.new
      route.serves |= stops
      route.add_identifier(feed_onestop_id:@feed.onestop_id, entity_id:entity.id)
      @gtfs_tl[entity] = route
      # Cache route
      @tl_by_onestop_id[route.onestop_id] = route
      log "    #{route.onestop_id}: #{route.name}"
    end
  end

  def load_tl_operators
    # Operators
    log "  operators"
    operators = Set.new
    @feed.operators_in_feed.each do |oif|
      entity = @gtfs.agency(oif.gtfs_agency_id)
      # Skip Operator if not found
      next unless entity
      # Find: (child gtfs routes) to (tl routes)
      #   note: .compact because some gtfs routes are skipped.
      routes = @gtfs.children(entity)
        .map { |route| @gtfs_tl[route] }
        .compact
        .to_set
      # Find: (tl routes) to (serves tl stops)
      stops = routes
        .map { |route| route.serves }
        .reduce(Set.new, :+)
      # Create Operator from GTFS
      operator = Operator.from_gtfs(entity, stops)
      operator.onestop_id = oif.operator.onestop_id # Override Onestop ID
      operator_original = operator # for merging geometry
      # ... or check if Operator exists, or another local Operator, or new.
      operator = Operator.find_by(onestop_id: operator.onestop_id) || @tl_by_onestop_id[operator.onestop_id] || operator
      # Merge convex hulls
      operator[:geometry] = Operator.convex_hull([operator, operator_original], as: :wkt, projected: false)
      # Copy Operator timezone to fill missing Stop timezones
      stops.each { |stop| stop.timezone ||= operator.timezone }
      # Add references and identifiers
      routes.each { |route| route.operator = operator }
      operator.serves ||= Set.new
      operator.serves |= routes
      operator.add_identifier(feed_onestop_id:@feed.onestop_id, entity_id:entity.id)
      @gtfs_tl[entity] = operator
      # Cache Operator
      @tl_by_onestop_id[operator.onestop_id] = operator
      # Add to found operators
      operators << operator
      log "    #{operator.onestop_id}: #{operator.name}"
    end
    # Return operators
    operators
  end

  def create_changeset(operators, import_level=0)
    raise ArgumentError.new('At least one operator required') if operators.empty?
    raise ArgumentError.new('import_level must be 0, 1, or 2.') unless (0..2).include?(import_level)
    log "Create Changeset"
    operators = operators
    routes = operators.map { |operator| operator.serves }.reduce(Set.new, :+)
    stops = routes.map { |route| route.serves }.reduce(Set.new, :+)
    changeset = Changeset.create()
    if import_level >= 0
      log "  operators: #{operators.size}"
      self.create_change_payloads(changeset, 'operator', operators.map { |e| make_change_operator(e) })
    end
    if import_level >= 1
      log "  stops: #{stops.size}"
      self.create_change_payloads(changeset, 'stop', stops.map { |e| make_change_stop(e) })
      log "  routes: #{routes.size}"
      self.create_change_payloads(changeset, 'route', routes.map { |e| make_change_route(e) })
    end
    if import_level >= 2
      trip_counter = 0
      ssp_counter = 0
      @gtfs.trip_chunks(STOP_TIMES_MAX_LOAD) do |trip_chunk|
        log "  trips: #{trip_counter} - #{trip_counter+trip_chunk.size}"
        trip_counter += trip_chunk.size
        ssp_chunk = []
        @gtfs.trip_stop_times(trip_chunk) do |trip,stop_times|
          log "    trip id: #{trip.trip_id}, stop_times: #{stop_times.size}"
          route = @gtfs.route(trip.route_id)
          # Create SSPs for all stop_time edges
          ssp_trip = []
          stop_times[0..-2].zip(stop_times[1..-1]).each do |origin,destination|
            ssp_trip << make_ssp(route,trip,origin,destination)
          end
          # Interpolate stop_times
          ScheduleStopPair.interpolate(ssp_trip)
          # Add to chunk
          ssp_chunk += ssp_trip
        end
        # Create changeset
        ssp_chunk.each_slice(CHANGE_PAYLOAD_MAX_ENTITIES) do |chunk|
          log "    ssps: #{ssp_counter} - #{ssp_counter+ssp_chunk.size}"
          ssp_counter += ssp_chunk.size
          self.create_change_payloads(changeset, 'scheduleStopPair', chunk.map { |e| make_change_ssp(e) })
        end
      end
    end
    # Apply changeset
    log "  changeset apply"
    changeset.apply!
    log "  changeset apply done"
  end

  def create_change_payloads(changeset, entity_type, entities)
    # Operators
    counter = 0
    entities.each_slice(CHANGE_PAYLOAD_MAX_ENTITIES).each do |chunk|
      counter += chunk.size
      changes = chunk.map do |entity|
        change = {}
        change['action'] = 'createUpdate'
        change[entity_type] = entity
        change
      end
      ChangePayload.create!(
        changeset: changeset,
        payload: {
          changes: changes
        }
      )
    end
  end

  def import_log
    @log.join("\n")
  end

  ##### GTFS by ID #####

  private

  def log(msg)
    @log << msg
    if Sidekiq::Logging.logger
      Sidekiq::Logging.logger.info msg
    elsif Rails.logger
      Rails.logger.info msg
    else
      puts msg
    end
  end

  ##### Create change payloads ######

  def make_change_operator(entity)
    {
      onestopId: entity.onestop_id,
      name: entity.name,
      identifiedBy: entity.identified_by.uniq,
      importedFromFeedOnestopId: @feed.onestop_id,
      geometry: entity.geometry,
      tags: entity.tags || {},
      timezone: entity.timezone,
      website: entity.website
    }
  end

  def make_change_stop(entity)
    {
      onestopId: entity.onestop_id,
      name: entity.name,
      identifiedBy: entity.identified_by.uniq,
      importedFromFeedOnestopId: @feed.onestop_id,
      geometry: entity.geometry,
      tags: entity.tags || {},
      timezone: entity.timezone
    }
  end

  def make_change_route(entity)
    {
      onestopId: entity.onestop_id,
      name: entity.name,
      identifiedBy: entity.identified_by.uniq,
      importedFromFeedOnestopId: @feed.onestop_id,
      operatedBy: entity.operator.onestop_id,
      serves: entity.stops.map(&:onestop_id),
      tags: entity.tags || {},
      geometry: entity.geometry
    }
  end

  def make_change_ssp(entity)
    {
      imported_from_feed_onestop_id: @feed.onestop_id,
      originOnestopId: entity.origin.onestop_id,
      originTimezone: entity.origin_timezone,
      originArrivalTime: entity.origin_arrival_time,
      originDepartureTime: entity.origin_departure_time,
      destinationOnestopId: entity.destination.onestop_id,
      destinationTimezone: entity.destination_timezone,
      destinationArrivalTime: entity.destination_arrival_time,
      destinationDepartureTime: entity.destination_departure_time,
      routeOnestopId: entity.route.onestop_id,
      trip: entity.trip,
      tripHeadsign: entity.trip_headsign,
      tripShortName: entity.trip_short_name,
      wheelchairAccessible: entity.wheelchair_accessible,
      dropOffType: entity.drop_off_type,
      pickupType: entity.pickup_type,
      shapeDistTraveled: entity.shape_dist_traveled,
      serviceStartDate: entity.service_start_date,
      serviceEndDate: entity.service_end_date,
      serviceDaysOfWeek: entity.service_days_of_week,
      serviceAddedDates: entity.service_added_dates,
      serviceExceptDates: entity.service_except_dates,
      windowStart: entity.window_start,
      windowEnd: entity.window_end,
      originTimepointSource: entity.origin_timepoint_source,
      destinationTimepointSource: entity.destination_timepoint_source
    }
  end

  def make_ssp(route, trip, origin, destination)
    # Generate an edge between an origin and destination for a given route/trip
    route = @gtfs_tl[route]
    origin_stop = @gtfs_tl[@gtfs.stop(origin.stop_id)]
    destination_stop = @gtfs_tl[@gtfs.stop(destination.stop_id)]
    service_period = @gtfs.service_period(trip.service_id)
    ScheduleStopPair.new(
      # Origin
      origin: origin_stop,
      origin_timezone: origin_stop.timezone,
      origin_arrival_time: origin.arrival_time.presence,
      origin_departure_time: origin.departure_time.presence,
      # Destination
      destination: destination_stop,
      destination_timezone: destination_stop.timezone,
      destination_arrival_time: destination.arrival_time.presence,
      destination_departure_time: destination.departure_time.presence,
      # Route
      route: route,
      # Trip
      trip: trip.id.presence,
      trip_headsign: (origin.stop_headsign || trip.trip_headsign).presence,
      trip_short_name: trip.trip_short_name.presence,
      wheelchair_accessible: trip.wheelchair_accessible.to_i,
      bikes_allowed: trip.bikes_allowed.to_i,
      # Stop Time
      drop_off_type: origin.drop_off_type.to_i,
      pickup_type: origin.pickup_type.to_i,
      shape_dist_traveled: origin.shape_dist_traveled.to_f,
      # service period
      service_start_date: service_period.start_date,
      service_end_date: service_period.end_date,
      service_days_of_week: service_period.iso_service_weekdays,
      service_added_dates: service_period.added_dates,
      service_except_dates: service_period.except_dates
    )
  end
end

if __FILE__ == $0
  # ActiveRecord::Base.logger = Logger.new(STDOUT)
  feedid = ARGV[0] || 'f-9q9-caltrain'
  filename = "tmp/transitland-feed-data/#{feedid}.zip"
  import_level = (ARGV[1] || 1).to_i
  feed = Feed.find_by!(onestop_id: feedid)
  graph = GTFSGraph.new(filename, feed)
  operators = graph.load_tl
  graph.create_changeset(operators, import_level=import_level)
end

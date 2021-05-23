"""
SRT Coordinator - Subscribes to `srtstatus` Redis channel for messages
typically published by the SRT Status process.  Uses the metadata in those
messages to coordinate the SRT hashpipe pipelines and update their status
buffers with relevant metadata from the telescope.
"""
module Coordinator

using Redis
using JSON
using RadioInterferometry

# Vector of Tuples containing (instances, sub-band factor)
const INSTANCES = [("blc00/0", 1), ("blc01/0", 2)]

function do_start(redis)
  values = String[]

  # Get synctime from redis
  synctime = get(redis, "sync_time")
  if synctime === nothing
    @warn "sync_time not found in redis"
  else
    push!(values, "SYNCTIME=$(synctime)")
  end

  # Get SRC_NAME from redis (for info message)
  src_name = hget(redis, "srt://$(INSTANCES[1][1])/status", "SRC_NAME")

  # Use blc00 PKTIDX as representative value for all nodes
  pktidx_str = hget(redis, "srt://$(INSTANCES[1][1])/status", "PKTIDX")
  pktidx=something(tryparse(Int64, pktidx_str))
  #@show pktidx

  # Set PKTSTART to future value.  pktidx is already as much as 1 second old,
  # so go 10 blocks into the future (~1.8 seconds from ~1 second ago == ~0.8
  # seconds into the future).
  # TODO Make this lead block count configurable
  lead_blocks = 10
  # TODO Read PIPERBLK from status buffer
  piperblk = 16384
  pktstart = pktidx + lead_blocks * piperblk
  push!(values, "PKTSTART=$(pktstart)")
  # Set dwell to 7200 seconds as safety switch
  # (will normally stop recording when track ends).
  dwell = 7200
  push!(values, "DWELL=$dwell")

  @info "scan start $src_name: setting PKTSTART=$pktstart DWELL=$dwell"

  # Publish start conditions
  publish(redis, "srt:///set", join(values, "\n"))
end

function do_stop(redis)
  @info "scan stop: setting PKTSTART=0 DWELL=0"

  # Publish start conditions
  publish(redis, "srt:///set", "PKTSTART=0\nDWELL=0")
end

function update_status(redis, oldmotion, json)
  status = JSON.parse(json)

  values = String[]
  startstop = :noop

  if haskey(status, "source")
    push!(values, "SRC_NAME=$(status["source"])")
  end
  if haskey(status, "azobs")
    push!(values, "AZ=$(status["azobs"])")
  end
  if haskey(status, "elobs")
    push!(values, "EL=$(status["elobs"])")
  end
  if haskey(status, "ra")
    push!(values, "RA=$(round(hms2ha(status["ra"])*15, digits=6))")
    push!(values, "RA_STR=$(status["ra"])")
  end
  if haskey(status, "dec")
    push!(values, "DEC=$(round(dms2deg(status["dec"]), digits=6))")
    push!(values, "DEC_STR=$(status["dec"])")
  end
  if haskey(status, "rcvr")
    push!(values, "FRONTEND=$(status["rcvr"])")
  end
  if haskey(status, "motion")
    motion = status["motion"]
    push!(values, "TRK_MODE=$(motion)")

    # Special case to avoid recording while "TRACKING" the "source" known as
    # `BeamPark`.  Basically treat it as a separate motion state `BeamPark`.
    if motion == "TRACKING" && status["source"] == "BeamPark"
      motion = "BeamPark"
    end

    # Ignore SLEWING if error is less that 0.01 degrees
    el = get(status, 0)
    azerr = get(status, 1) # if missing, assume a large
    elerr = get(status, 1) # error to assume slew is real
    err = hypot(azerr * cosd(el), elerr)

    if motion == "SLEWING" && err < 0.01
      @info "ignoring slewing with error < 0.01 degrees"
    else
      # Handle changes in motion state
      # Tracking to non-tracking => stop recording
      # Non-tracking to tracking => start recording
      if motion != oldmotion[]
        startstop = oldmotion[] == "TRACKING" ? :stop  :
                       motion   == "TRACKING" ? :start : :noop
        @info "motion changed: $(oldmotion[]) -> $(motion) [$(startstop)]"
        # Remember current motion state
        oldmotion[] = motion
      end
    end

  end

  @debug values

  if !isempty(values)
    publish(redis, "srt:///set", join(values, "\n"))
  end

  if haskey(status, "lofreq")
    # Complete hack for now...
    lofreq = status["lofreq"]
    obsfreq0 = lofreq + 187.5 / 64 * 31.5

    for (instance, subband) in INSTANCES
      publish(redis,
              "srt://$(instance)/set", "OBSFREQ=$(obsfreq0 + subband*187.5)")
    end
  end

  startstop == :start && do_start(redis)
  startstop == :stop  && do_stop(redis)

  nothing
end

function update_status_trycatch(redis, oldmotion, json)
  try
    update_status_trycatch(redis, oldmotion, json)
  catch ex
    @error "error updating status" exception=ex
  end
end

function main(args)
  redishost = get(ENV, "REDISHOST", "redishost")
  redis = RedisConnection(host=redishost)
  sub = open_subscription(redis)
  oldmotion = Ref{String}("NA")
  subscribe(sub, "srtstatus", m->update_status_trycatch(redis, oldmotion, m))

  # Allow CTRL-C to generate InterruptException (requires Julia >= v1.5.0)
  Base.exit_on_sigint(false)

  try
    while true
      sleep(1)
    end
  catch e
    if isa(e, InterruptException)
      @debug "got CTRL-C"
    else
      @error e
    end
  end

  @info "coordinator shutting down"
  disconnect(sub)
  disconnect(redis)
end

end # module Coordinator

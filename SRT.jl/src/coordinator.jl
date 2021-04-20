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

function update_status(redis, json)
  status = JSON.parse(json)

  values = []

  if haskey(status, "source")
    push!(values, "SRC_NAME=$(status["source"])")
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
    push!(values, "TRK_MODE=$(status["motion"])")
  end

  @debug values

  if !isempty(values)
    publish(redis, "srt:///set", join(values, "\n"))
  end

  if haskey(status, "lofreq")
    # Complete hack for now...
    lofreq = status["lofreq"]
    obsfreq0 = lofreq + 187.5 / 64 * 31.5

    publish(redis, "srt://blc00/0/set", "OBSFREQ=$(obsfreq0 + 1*187.5)")
    publish(redis, "srt://blc01/0/set", "OBSFREQ=$(obsfreq0 + 2*187.5)")
  end
end

function main(args)
  redishost = get(ENV, "REDISHOST", "redishost")
  redis = RedisConnection(host=redishost)
  sub = open_subscription(redis)
  subscribe(sub, "srtstatus", m->update_status(redis, m))

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

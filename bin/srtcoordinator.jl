#!/bin/bash
#=
exec julia --color=yes --startup-file=no "${BASH_SOURCE[0]}" "$@"
=#

using Redis
using JSON
using RadioInterferometry

function update_status(redis, json)
  status = JSON.parse(json)

  values = [
            "SRC_NAME=$(status["source"])",
            "RA=$(round(hms2h(status["ra"])*15, digits=6))",
            "RA_STR=$(status["ra"])",
            "DEC=$(round(dms2d(status["dec"]), digits=6))",
            "DEC_STR=$(status["dec"])",
            "FRONTEND=$(status["rcvr"])"
           ]

  @debug values

  publish(redis, "srt:///set", join(values, "\n"))

  # Complete hack for now...
  lofreq = status["lofreq"]
  obsfreq0 = lofreq + 187.5 / 64 * 31.5

  publish(redis, "srt://blc00/0/set", "OBSFREQ=$(obsfreq0 + 1*187.5)")
  publish(redis, "srt://blc01/0/set", "OBSFREQ=$(obsfreq0 + 2*187.5)")
end

function run_controller(redishost="redishost")
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
  #unsubscribe(sub, "srtstatus")
  disconnect(sub)
  disconnect(redis)
end

run_controller()

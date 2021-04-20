#!/bin/bash
#=
exec julia --color=yes --startup-file=no "${BASH_SOURCE[0]}" "$@"
=#

using Dates
using Sockets
using DelimitedFiles
using Redis
using JSON

"""
This NamedTuple represents the fields from the SRT antenna control/status
server.  The server provides these fields in a comma-delimited format.
"""
SRTStatus = @NamedTuple begin
	datetime::DateTime
	status::AbstractString
	source::AbstractString
	azobs::Float64
	elobs::Float64
	ra::AbstractString
	dec::AbstractString
	glon::AbstractString
	glat::AbstractString
	azcmd::Float64
	elcmd::Float64
	azerr::Float64
	elerr::Float64
	azpnt::Float64
	elpnt::Float64
	refract::Float64
	azoff::Float64
	eloff::Float64
	raoff::Float64
	decoff::Float64
	glonoff::Float64
	glatoff::Float64
	rcvr::AbstractString
	lofreq::Float64
	motion::AbstractString
end

function srtdatetime(s)
  y, d, t = split(s, '-')
  Date(y[19:end]) + Day(d) - Day(1) + Time(t)
end

function query_server(socket::TCPSocket)
  write(socket, "antennaParameters\n")
  data = readdlm(readavailable(socket), ',')
  # Parse datetime
  data[1] = srtdatetime(data[1])
  SRTStatus(data)
end

function run_client(socket::TCPSocket, redis)
  # Start timer (no delay, interval=1 second)
  timer = Timer(0, interval=1) do t
    status = query_server(socket)
    if isnothing(redis)
      @info values(status)
    else
      @debug values(status)
      publish(redis, "srtstatus", JSON.json(status))
    end
  end

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

  @info "client shutting down"
  close(timer)
end

function run_client(ip::IPv4, port=54000; redishost="redishost")
  redis = isnothing(redishost) ? nothing : RedisConnection(host=redishost)
  try
    socket = connect(ip, port)
    try
      run_client(socket, redis)
    finally
      close(socket)
    end
  finally
    isnothing(redis) || disconnect(redis)
  end
end

run_client(port=54000; redishost="redishost") = run_client(ip"127.0.0.1", port; redishost=redishost)

function run_client(host::AbstractString,
                    port::AbstractString,
                    redishost="redishost")
  h = getaddrinfo(host, IPv4)
  p = parse(Int, port)
  run_client(h, p, redishost)
end

if abspath(PROGRAM_FILE) == @__FILE__

defhost = "localhost"
defport = "40000"
push!(ARGS, "$(defhost):$(defport)")

host, port = split(ARGS[1]*":"*defport, ':')

isempty(host) && (host = "localhost")
isempty(port) && (port = "40000")

@info "connecting to server at:" host port

#run_client(host, port)

end

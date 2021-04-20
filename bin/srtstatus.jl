#!/bin/bash
#=
exec julia --color=yes --startup-file=no "${BASH_SOURCE[0]}" "$@"
=#

import Pkg
@assert Pkg.project().name == "SRT"
Pkg.instantiate()

import SRT
SRT.Status.main(ARGS)

#!/usr/bin/env bash

ADD_HEAD='1i Module,Methods,Stable,Unstable,Any,Vararg,Generic,TcFail,NoFuel'

find . -maxdepth 1 -name "*-agg.txt" -exec cat {} + | sort | sed "$ADD_HEAD" > aggregate.csv

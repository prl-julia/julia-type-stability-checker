#!/usr/bin/env bash

ADD_HEAD='1i Module,MethodsGood,Stable,Unstable,NoFuel,DBStable,DBUnstable,DBNoFuel'

find . -maxdepth 2 -name "*-agg.txt" -exec cat {} + | sort | sed "$ADD_HEAD" > aggregate.csv

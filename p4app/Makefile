# Makefile
# Build/run wiring for the BMv2 track on top of p4lang/tutorials.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

TUTORIALS ?= $(HOME)/tutorials
P4VENV    ?= $(HOME)/p4venv

BMV2_SWITCH_EXE = simple_switch_grpc
TOPO            = topology.json

include $(TUTORIALS)/utils/Makefile

RUN_SCRIPT = $(TUTORIALS)/utils/run_exercise.py

.RECIPEPREFIX := >
%.json: %.p4
> $(P4C) --p4v 16 --p4runtime-files $(BUILD_DIR)/$*.p4.p4info.txt -o $(BUILD_DIR)/$@ $*.p4

run: build
> sudo PATH=$(PATH) $(P4VENV)/bin/python3 $(RUN_SCRIPT) -t $(TOPO) $(run_args)

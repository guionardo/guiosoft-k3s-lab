SHELL := /bin/bash

.PHONY: help discovery

help:
	@echo "guiosoft-k3s-lab"
	@echo
	@echo "Targets disponíveis:"
	@echo "  make discovery   Executa discovery read-only deste host"

# Use sudo because some useful inventory information is only visible to root.
discovery:
	sudo bash scripts/discovery.sh

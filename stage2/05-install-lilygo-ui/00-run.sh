#!/bin/bash -e

# Install the complete LILYGO UI package set before stage2 is exported as the
# lite image. Stage5 shares this implementation.
exec "${BASE_DIR}/stage5/01-install-lilygo-ui/00-run.sh"

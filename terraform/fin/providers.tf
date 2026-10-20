terraform {
  required_version = ">= 1.9.0"

  required_providers {
    verda = {
      source = "verda-cloud/verda"
      # 1.1.4 is the first release whose destroy deletes the OS volume again
      # (issue #17) and whose create waits for the instance to be running with
      # an address. Both matter to a site that exists only during a window.
      version = "~> 1.1, >= 1.1.4"
    }
  }
}

# Credentials are never set here. The provider reads VERDA_CLIENT_ID and
# VERDA_CLIENT_SECRET from the environment, which the scripts load from the
# gitignored .env.
provider "verda" {}

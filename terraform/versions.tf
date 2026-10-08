# Tool and provider versions. Pinned so every run creates the same thing.
terraform {
  required_version = "= 1.16.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.68.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource gets these tags, so costs and leftovers are easy to find.
  default_tags {
    tags = {
      Project = "inventorise"
      Managed = "terraform"
    }
  }
}

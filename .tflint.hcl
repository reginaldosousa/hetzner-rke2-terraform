# tflint --init && tflint --recursive --config "$(pwd)/.tflint.hcl"
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs" { enabled = true }
rule "terraform_naming_convention" { enabled = true }

# terraform/infra and terraform/cluster are root configurations, not reusable
# modules; the main.tf/outputs.tf layout rule doesn't fit them.
rule "terraform_standard_module_structure" { enabled = false }

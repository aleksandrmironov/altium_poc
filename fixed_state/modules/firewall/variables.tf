# modules/firewall/variables.tf
# Inputs:
#   firewall_subnet_id  - /28 subnet dedicated to firewall endpoint
#   vpc_id              - existing VPC ID
#   allowed_fqdns       - list of allowed egress domains
#                         default: ["example.com", "secureweb.com"]
#   environment         - tag value
# TODO: implement

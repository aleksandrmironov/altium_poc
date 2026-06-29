# modules/firewall/outputs.tf
# Key outputs:
#   firewall_endpoint_id  - used by modules/vpc/ to set EC2 app route table
#                           aws_networkfirewall_firewall.this
#                             .firewall_status[0]
#                             .sync_states[*].attachment[0].endpoint_id
#   firewall_arn          - for smoke tests and logging config
# TODO: implement

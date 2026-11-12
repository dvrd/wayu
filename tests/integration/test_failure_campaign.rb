#!/usr/bin/env ruby
# Keep the portable filesystem/process campaign in ordinary and ASan CI.
require_relative '../scenarios/failure_campaign.scenario.test'
FailureCampaign.new.run

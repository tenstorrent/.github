#!/usr/bin/env ruby
# frozen_string_literal: true

# Composite actions cannot share input definitions, so docker-publish and
# docker-bake-publish each declare the gate inputs. This check fails when the
# copies drift apart. Run from anywhere: ruby actions/check-consistency.rb
#
# Checked:
#   - an input declared by both actions has the same description and default
#   - the env both `gate` steps pass to gate.sh agrees on every shared key
#   - bake.sh pins the same SBOM scanner digest as docker-publish's
#     sbom-generator default
#   - every `uses:` is pinned to a full commit sha

require 'yaml'

ROOT = __dir__
PUBLISH = File.join(ROOT, 'docker-publish', 'action.yml')
BAKE = File.join(ROOT, 'docker-bake-publish', 'action.yml')
BAKE_SH = File.join(ROOT, 'docker-bake-publish', 'scripts', 'bake.sh')

# Differ on purpose: each step reads its report id from its own earlier step.
GATE_ENV_PER_ACTION = %w[REPORT_ROOT].freeze

errors = []
publish = YAML.safe_load(File.read(PUBLISH))
bake = YAML.safe_load(File.read(BAKE))

shared = publish['inputs'].keys & bake['inputs'].keys
shared.each do |name|
  %w[description default required].each do |field|
    a = publish['inputs'][name][field]
    b = bake['inputs'][name][field]
    next if a == b

    errors << "input '#{name}': #{field} differs\n    docker-publish:      #{a.inspect}\n    docker-bake-publish: #{b.inspect}"
  end
end

gate_env = lambda do |action|
  step = action['runs']['steps'].find { |s| s['id'] == 'gate' }
  step ? step['env'] : {}
end
publish_env = gate_env.call(publish)
bake_env = gate_env.call(bake)
errors << 'a gate step is missing or has no env' if publish_env.empty? || bake_env.empty?
((publish_env.keys & bake_env.keys) - GATE_ENV_PER_ACTION).each do |key|
  next if publish_env[key] == bake_env[key]

  errors << "gate env '#{key}' differs: #{publish_env[key].inspect} vs #{bake_env[key].inspect}"
end
# Everything gate.sh needs from the bake action must also be passed by docker-publish.
(bake_env.keys - publish_env.keys).each do |key|
  errors << "gate env '#{key}' is passed by docker-bake-publish only"
end

generator = publish['inputs']['sbom-generator']['default'].to_s
action_digest = generator[/@(sha256:[0-9a-f]{64})\z/, 1]
script_digest = File.read(BAKE_SH)[/^\s*SYFT_SCANNER_DIGEST="(sha256:[0-9a-f]{64})"/, 1]
if action_digest.nil?
  errors << "docker-publish sbom-generator default is not pinned by digest: #{generator}"
elsif script_digest.nil?
  errors << 'bake.sh does not set SYFT_SCANNER_DIGEST to a sha256 digest'
elsif action_digest != script_digest
  errors << "SBOM scanner digest differs: action.yml #{action_digest}, bake.sh #{script_digest}"
end

{ PUBLISH => publish, BAKE => bake }.each do |path, action|
  action['runs']['steps'].each do |step|
    uses = step['uses']
    next if uses.nil? || uses.start_with?('./')
    next if uses.match?(/@[0-9a-f]{40}\z/)

    errors << "#{path.delete_prefix("#{ROOT}/")}: '#{uses}' is not pinned to a full commit sha"
  end
end

if errors.empty?
  puts "ok: #{shared.size} shared inputs, gate env, scanner digest and action pins are consistent"
else
  warn errors.map { |e| "- #{e}" }.join("\n")
  exit 1
end

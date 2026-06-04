#!/usr/bin/env ruby
# add_limm_files.rb — adds Limm/*.swift to the Xcode project at build time.
# Run from repo root: ruby scripts/add_limm_files.rb
# Requires: gem install xcodeproj

require 'xcodeproj'

PROJECT_PATH = 'V2rayU.xcodeproj'
TARGET_NAME  = 'V2rayU'
LIMM_FILES   = %w[
  V2rayU/Limm/LimmConfig.swift
  V2rayU/Limm/LimmCheckin.swift
  V2rayU/Limm/LimmLogReporter.swift
  V2rayU/Limm/LimmUpdater.swift
  V2rayU/Limm/LimmFullTest.swift
  V2rayU/Limm/LimmSecrets.swift
]

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == TARGET_NAME }
abort "Target #{TARGET_NAME} not found" unless target

# Find or create Limm group inside V2rayU group
v2rayu_group = project.main_group.find_subpath('V2rayU', false)
abort 'V2rayU group not found' unless v2rayu_group

limm_group = v2rayu_group.find_subpath('Limm', false) ||
             v2rayu_group.new_group('Limm', 'Limm')

sources_phase = target.source_build_phase

LIMM_FILES.each do |rel_path|
  # Skip if already in project
  next if project.files.any? { |f| f.real_path.to_s.end_with?(File.basename(rel_path)) rescue false }

  abs_path = File.join(Dir.pwd, rel_path)
  next unless File.exist?(abs_path)

  file_ref = limm_group.new_file(abs_path)
  sources_phase.add_file_reference(file_ref)
  puts "Added #{rel_path}"
end

project.save
puts 'xcodeproj saved.'

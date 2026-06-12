#!/usr/bin/env ruby
# add_awg_resource.rb — bundle Build/awg-core/ (amneziawg-go + awg) into the app Resources.
# Mirrors how Build/v2ray-core is referenced as a folder resource. Run AFTER the CI step
# that builds Build/awg-core/. Requires: gem install xcodeproj.
#
# Result: Contents/Resources/awg-core/{amneziawg-go,awg} — matched by
# LimmAWGProcess.swift's AppResourcesPath + "/awg-core/amneziawg-go".

require 'xcodeproj'

PROJECT_PATH = 'V2rayU.xcodeproj'
TARGET_NAME  = 'V2rayU'
AWG_DIR_REL  = 'Build/awg-core'

abort "#{AWG_DIR_REL} not found — run the awg build step first" unless Dir.exist?(AWG_DIR_REL)

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == TARGET_NAME }
abort "Target #{TARGET_NAME} not found" unless target

# Skip if already referenced.
already = project.files.any? { |f| (f.path.to_s == AWG_DIR_REL) rescue false }
unless already
  # Add as a folder reference (lastKnownFileType = folder) so the whole dir is copied.
  ref = project.main_group.new_file(File.join(Dir.pwd, AWG_DIR_REL))
  ref.last_known_file_type = 'folder'
  ref.name = 'awg-core'
  target.resources_build_phase.add_file_reference(ref)
  puts "Added #{AWG_DIR_REL} as Resources folder reference."
else
  puts "#{AWG_DIR_REL} already referenced — skipping."
end

project.save
puts 'xcodeproj saved (awg-core).'

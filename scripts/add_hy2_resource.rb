#!/usr/bin/env ruby
# add_hy2_resource.rb — bundle Build/hy2-core/ (hysteria2 universal binary) into app Resources.
# Mirrors add_awg_resource.rb. Run AFTER the CI step that downloads Build/hy2-core/hysteria2.
# Requires: gem install xcodeproj.
#
# Result: Contents/Resources/hy2-core/hysteria2 — matched by
# LimmHy2Process.swift's AppResourcesPath + "/hy2-core/hysteria2".

require 'xcodeproj'

PROJECT_PATH = 'V2rayU.xcodeproj'
TARGET_NAME  = 'V2rayU'
HY2_DIR_REL  = 'Build/hy2-core'

abort "#{HY2_DIR_REL} not found — run the hysteria2 download step first" unless Dir.exist?(HY2_DIR_REL)

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == TARGET_NAME }
abort "Target #{TARGET_NAME} not found" unless target

# Skip if already referenced.
already = project.files.any? { |f| (f.path.to_s == HY2_DIR_REL) rescue false }
unless already
  ref = project.main_group.new_file(File.join(Dir.pwd, HY2_DIR_REL))
  ref.last_known_file_type = 'folder'
  ref.name = 'hy2-core'
  target.resources_build_phase.add_file_reference(ref)
  puts "Added #{HY2_DIR_REL} as Resources folder reference."
else
  puts "#{HY2_DIR_REL} already referenced — skipping."
end

project.save
puts 'xcodeproj saved (hy2-core).'

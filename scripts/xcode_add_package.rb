#!/usr/bin/env ruby
# Adds a remote Swift package to Shirox.xcodeproj, pinned to an exact version, and links the given
# products into the three app targets (Shirox_iOS, which Mac Catalyst builds too, Shirox_macOS and
# Shirox_tvOS). The test target gets them through the app it's hosted in.
# Usage: ruby scripts/xcode_add_package.rb <repository-url> <exact-version> <product> [<product> ...]
# Idempotent: a package already referenced by URL, or a product a target already links, is skipped.
require 'xcodeproj'

url, version, *products = ARGV
abort "usage: xcode_add_package.rb <repository-url> <exact-version> <product> ..." if url.nil? || version.nil? || products.empty?

proj = Xcodeproj::Project.open('Shirox.xcodeproj')
app_targets = %w[Shirox_iOS Shirox_macOS Shirox_tvOS].map { |n| proj.targets.find { |t| t.name == n } }

package = proj.root_object.package_references.find { |p| p.respond_to?(:repositoryURL) && p.repositoryURL == url }
unless package
  package = proj.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url
  package.requirement = { 'kind' => 'exactVersion', 'version' => version }
  proj.root_object.package_references << package
  puts "added package #{url} @ #{version}"
end

app_targets.each do |target|
  products.each do |product|
    if target.package_product_dependencies.any? { |d| d.product_name == product }
      puts "#{target.name} already links #{product}"
      next
    end
    dependency = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package
    dependency.product_name = product
    target.package_product_dependencies << dependency
    build_file = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
    puts "#{target.name} links #{product}"
  end
end

proj.save
puts "saved #{proj.path}"

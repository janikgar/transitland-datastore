# == Schema Information
#
# Table name: operators
#
#  id                                 :integer          not null, primary key
#  name                               :string(255)
#  tags                               :hstore
#  created_at                         :datetime
#  updated_at                         :datetime
#  onestop_id                         :string(255)
#  geometry                           :spatial          geometry, 4326
#  created_or_updated_in_changeset_id :integer
#  destroyed_in_changeset_id          :integer
#  version                            :integer
#  current                            :boolean
#
# Indexes
#
#  index_operators_on_current          (current)
#  index_operators_on_onestop_id       (onestop_id) UNIQUE
#  operators_cu_in_changeset_id_index  (created_or_updated_in_changeset_id)
#  operators_d_in_changeset_id_index   (destroyed_in_changeset_id)
#

FactoryGirl.define do
  factory :operator do
    onestop_id { Faker::OnestopId.operator }
    name { Faker::Company.name }
    geometry { "POINT(#{rand(-124.4..-90.1)} #{rand(28.1..50.0095)})" }
  end
end
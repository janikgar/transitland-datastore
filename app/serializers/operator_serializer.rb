# == Schema Information
#
# Table name: current_operators
#
#  id                                 :integer          not null, primary key
#  name                               :string(255)
#  tags                               :hstore
#  created_at                         :datetime
#  updated_at                         :datetime
#  onestop_id                         :string(255)
#  geometry                           :spatial          geometry, 4326
#  created_or_updated_in_changeset_id :integer
#  version                            :integer
#
# Indexes
#
#  #c_operators_cu_in_changeset_id_index  (created_or_updated_in_changeset_id)
#  index_current_operators_on_onestop_id  (onestop_id) UNIQUE
#

class OperatorSerializer < CurrentEntitySerializer
  attributes :name,
             :onestop_id,
             :geometry,
             :tags,
             :created_at,
             :updated_at
end
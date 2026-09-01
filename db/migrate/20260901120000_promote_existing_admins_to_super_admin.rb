# frozen_string_literal: true

# Historically the "admin" role had unrestricted access (CanCanCan `manage :all`).
# The role split introduces `super_admin` as the new unrestricted role and demotes
# `admin` to a settings-gated role. To avoid locking existing admins out of the
# settings they currently manage, promote all existing admins to super_admin.
class PromoteExistingAdminsToSuperAdmin < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # Use raw SQL to avoid depending on model-level validations/constants.
    execute(<<~SQL.squish)
      UPDATE users SET role = 'super_admin' WHERE role = 'admin'
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE users SET role = 'admin' WHERE role = 'super_admin'
    SQL
  end
end

# encoding utf-8

require_relative 'bolt.rb'

module Carto
  class GhostTablesManager
    MUTEX_REDIS_KEY = 'ghost_tables_working'.freeze
    MUTEX_TTL_MS = 60000

    def initialize(user_id)
      @user = ::User.where(id: user_id).first
    end

    def link_ghost_tables
      cartodbfied_tables = fetch_cartobfied_tables

      return if user_tables_synced_with_db?(cartodbfied_tables)

      if safe_async?(cartodbfied_tables)
        ::Resque.enqueue(::Resque::UserJobs::SyncTables::LinkGhostTables, @user.id)
      else
        link_ghost_tables_synchronously
      end
    end

    def link_ghost_tables_synchronously
      sync_user_tables_with_db unless user_tables_synced_with_db?(fetch_cartobfied_tables)
    end

    private

    # determine linked tables vs cartodbfied tables consistency; i.e.: needs to run sync
    def user_tables_synced_with_db?(cartodbfied_tables)
      cartodbfied_tables = fetch_cartobfied_tables

      cartodbfied_tables.reject(&:unaltered?).empty? && find_dropped_tables(cartodbfied_tables).empty?
    end

    # Check if any unsafe stale (dropped or renamed) tables will be shown to the user
    def safe_async?(cartodbfied_tables)
      find_dropped_tables(cartodbfied_tables).empty? && cartodbfied_tables.select(&:renamed?).empty?
    end

    def sync_user_tables_with_db
      bolt = Carto::Bolt.new("#{@user.username}:#{MUTEX_REDIS_KEY}", ttl_ms: MUTEX_TTL_MS)

      got_locked = bolt.run_locked { sync }

      CartoDB::Logger.info(message: 'Ghost table race condition avoided', user: @user) unless got_locked
    end

    def sync
      cartodbfied_tables = fetch_cartobfied_tables

      # Update table_id on UserTables with physical tables with changed oid
      cartodbfied_tables.select(&:regenerated?).each(&:regenerate_user_table)

      # Create UserTables for non linked Tables
      cartodbfied_tables.select(&:new?).each(&:create_user_table)

      # Relink tables that have been renamed through the SQL API
      cartodbfied_tables.select(&:renamed?).each(&:rename_user_table_vis)

      # Unlink tables that have been created trhought the SQL API
      find_dropped_tables(cartodbfied_tables).each(&:drop_user_table)
    end

    # this method searchs for tables with all the columns needed in a cartodb table.
    # it does not check column types, and only the latest cartodbfication trigger attached (test_quota_per_row)
    def fetch_cartobfied_tables
      cartodb_columns = (Table::CARTODB_REQUIRED_COLUMNS + [Table::THE_GEOM_WEBMERCATOR]).map { |col| "'#{col}'" }
                                                                                         .join(',')

      sql = %{
        WITH a as (
          SELECT table_name, table_name::regclass::oid reloid, count(column_name::text) cdb_columns_count
          FROM information_schema.columns c, pg_tables t, pg_trigger tg
          WHERE
            t.tablename = c.table_name AND
            t.schemaname = c.table_schema AND
            c.table_schema = '#{@user.database_schema}' AND
            t.tableowner = '#{@user.database_username}' AND
            column_name IN (#{cartodb_columns}) AND
            tg.tgrelid = (quote_ident(t.schemaname) || '.' || quote_ident(t.tablename))::regclass::oid AND
            tg.tgname = 'test_quota_per_row'
          GROUP BY 1)
        SELECT table_name, reloid FROM a WHERE cdb_columns_count = #{cartodb_columns.split(',').length}
      }

      @user.in_database(as: :superuser)[sql].all.map do |record|
        Carto::TableRepresentation.new(record[:reloid], record[:table_name], @user)
      end
    end

    # Tables that have been dropped via API but have an old UserTable
    def find_dropped_tables(cartodbfied_tables)
      linked_tables = @user.tables.all.map do |user_table|
        Carto::TableRepresentation.new(user_table.table_id, user_table.name, @user)
      end

      non_linked = linked_tables - cartodbfied_tables

      # Safety to not depend on regerate to run first
      non_linked.reject(&:regenerated?)
    end
  end

  class TableRepresentation
    attr_reader :id, :name, :user

    def initialize(id, name, user)
      @id = id
      @name = name
      @user = user
    end

    # Grabs the Table associated with this LinkedTable.
    def table
      user_tables = ::UserTable.where(table_id: id, user_id: user.id)

      first = user_tables.first

      if user_tables.count > 1
        CartoDB::Logger.warning(message: 'Duplicate UserTables detected', user: user, table_name: first.name)
      end

      first ? Table.new(user_table: first) : nil
    end

    def new?
      !user_table_with_matching_id && !user_table_with_matching_name
    end

    def renamed?
      !!user_table_with_matching_id && !user_table_with_matching_name
    end

    def regenerated?
      !user_table_with_matching_id && !!user_table_with_matching_name
    end

    def unaltered?
      !new? && !renamed?
    end

    def user_table_with_matching_id
      user.tables.where(table_id: id).first
    end

    def user_table_with_matching_name
      user.tables.where(name: name).first
    end

    def create_user_table
      CartoDB::Logger.debug(message: 'ghost tables',
                            action: 'linking new table',
                            user: @user,
                            new_table: name,
                            new_table_id: id)

      # TODO: Use Carto::UserTable when it's ready and stop the Table <-> ::UserTable madness
      new_table = ::Table.new(user_table: ::UserTable.new.set_fields({ user_id: @user.id, table_id: id, name: name },
                                                                     [:user_id, :table_id, :name]))

      new_table.register_table_only = true
      new_table.keep_user_database_table = true

      new_table.save
    end

    def rename_user_table_vis
      CartoDB::Logger.debug(message: 'ghost tables',
                            action: 'relinking renamed table',
                            user: @user,
                            renamed_table: name,
                            renamed_table_id: id)

      user_table_vis = user_table_with_matching_id.table_visualization

      user_table_vis.register_table_only = true
      user_table_vis.name = name

      user_table_vis.store
    end

    def drop_user_table
      CartoDB::Logger.debug(message: 'ghost tables',
                            action: 'unlinking dropped table',
                            user: @user,
                            dropped_table: name,
                            dropped_table_id: id)

      # TODO: Use Carto::UserTable when it's ready and stop the Table <-> ::UserTable madness
      table_to_drop = ::Table.new(user_table: @user.tables.where(table_id: id, name: name).first)

      table_to_drop.keep_user_database_table = true

      table_to_drop.destroy
    end

    def regenerate_user_table
      CartoDB::Logger.debug(message: 'ghost tables',
                            action: 'regenerating table_id',
                            user: @user,
                            dropped_table: name,
                            dropped_table_id: id)

      user_table = user_table_with_matching_name

      user_table.table_id = id
      user_table.save
    end

    def physical_table_exists?
      !!fetch_oid_and_relname
    end

    def fetch_oid_and_relname
      @user.in_database(as: :superuser)
           .select(:pg_class__oid, :pg_class__relname)
           .from(:pg_class)
           .join_table(:inner, :pg_namespace, oid: :relnamespace)
           .where(relkind: 'r', nspname: user.database_schema, pg_class__oid: id, pg_class__relname: name)
           .first
    end

    def eql?(other)
      id.eql?(other.id) && name.eql?(other.name) && user.id.eql?(other.user.id)
    end

    def ==(other)
      eql?(other)
    end

    def hash
      [id, name, user.id].hash
    end
  end
end
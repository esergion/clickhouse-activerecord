module ClickhouseActiverecord
  class SchemaDumper < ::ActiveRecord::ConnectionAdapters::SchemaDumper

    attr_accessor :simple

    class << self
      def dump(connection = ActiveRecord::Base.connection, stream = STDOUT, config = ActiveRecord::Base, default = false)
        dumper = connection.create_schema_dumper(generate_options(config))
        dumper.simple = default
        dumper.dump(stream)
        stream
      end
    end

    private

    def header(stream)
      stream.puts <<HEADER
# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `rails
# #{simple ? 'db' : 'clickhouse'}:schema:load`. When creating a new database, `rails #{simple ? 'db' : 'clickhouse'}:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

#{simple ? 'ActiveRecord' : 'ClickhouseActiverecord'}::Schema.define(#{define_params}) do

HEADER
    end

    def tables(stream)
      functions = @connection.functions
      functions.each do |function|
        function(function, stream)
      end

      sorted_tables = @connection.tables.sort {|a,b| @connection.show_create_table(a).match(/^CREATE\s+(MATERIALIZED\s+)?VIEW/) ? 1 : a <=> b }
      sorted_tables.each do |table_name|
        table(table_name, stream) unless ignored?(table_name)
      end
    end

    def table(table, stream)
      if table.match(/^\.inner/).nil?
        unless simple
          stream.puts "  # TABLE: #{table}"
          sql = @connection.show_create_table(table)
          stream.puts "  # SQL: #{sql.gsub(/ENGINE = Replicated(.*?)\('[^']+',\s*'[^']+',?\s?([^\)]*)?\)/, "ENGINE = \\1(\\2)")}" if sql
          # super(table.gsub(/^\.inner\./, ''), stream)

          # detect view table
          match = sql.match(/^CREATE\s+(MATERIALIZED\s+)?VIEW/)
        end

        # Copy from original dumper
        columns = @connection.columns(table)
        nested_data = extract_nested_columns(columns)

        begin
          tbl = StringIO.new

          # first dump primary key column
          pk = @connection.primary_key(table)

          tbl.print "  create_table #{remove_prefix_and_suffix(table).inspect}"

          unless simple
            # Add materialize flag
            tbl.print ', view: true' if match
            tbl.print ', materialized: true' if match && match[1].presence
          end

          case pk
          when String
            tbl.print ", primary_key: #{pk.inspect}" unless pk == "id"
            pkcol = columns.detect { |c| c.name == pk }
            pkcolspec = column_spec_for_primary_key(pkcol)
            if pkcolspec.present?
              tbl.print ", #{format_colspec(pkcolspec)}"
            end
          when Array
            tbl.print ", primary_key: #{pk.inspect}"
          else
            tbl.print ", id: false"
          end

          unless simple
            table_options = @connection.table_options(table)
            if table_options.present?
              table_options = format_options(table_options)
              table_options.gsub!(/Buffer\('[^']+'/, 'Buffer(\'#{connection.database}\'')
              tbl.print ", #{table_options}"
            end
          end

          tbl.puts ", force: :cascade do |t|"

          # then dump all non-primary key columns
          if simple || !match
            columns.each do |column|
              raise StandardError, "Unknown type '#{column.sql_type}' for column '#{column.name}'" unless @connection.valid_type?(column.type)
              next if column.name == pk || column.name =~ /\./
              type, colspec = column_spec(column)
              tbl.print "    t.#{type} #{column.name.inspect}"
              tbl.print ", #{format_colspec(colspec)}" if colspec.present?
              tbl.puts
            end

            nested_data.each do |nested_name, nested_columns|
              tbl.print "    t.column #{nested_name.inspect}, \"Nested("
              nested_columns.each do |column|
                tbl.print "#{column.name.split(/\./).last} #{column.sql_type.gsub(/\AArray\((.*)\)/, "\\1")}"
                tbl.print ", " if column != nested_columns.last
              end
              tbl.print ")\""
              tbl.print ", null: false" if !nested_columns.first.null
              tbl.puts
            end
          end

          indexes = sql.scan(/INDEX \S+ \S+ TYPE .*? GRANULARITY \d+/)
          if indexes.any?
            tbl.puts ''
            indexes.flatten.map!(&:strip).each do |index|
              tbl.puts "    t.index #{index_parts(index).join(', ')}"
            end
          end

          tbl.puts "  end"
          tbl.puts

          tbl.rewind
          stream.print tbl.read
        rescue => e
          stream.puts "# Could not dump table #{table.inspect} because of following #{e.class}"
          stream.puts "#   #{e.message}"
          stream.puts
        end
      end
    end

    def function(function, stream)
      stream.puts "  # FUNCTION: #{function}"
      sql = @connection.show_create_function(function)
      stream.puts "  # SQL: #{sql}" if sql
      stream.puts "  create_function \"#{function}\", \"#{sql.gsub(/^CREATE FUNCTION (.*?) AS/, '').strip}\"" if sql
    end

    def format_options(options)
      if options && options[:options]
        options[:options].gsub!(/^Replicated(.*?)\('[^']+',\s*'[^']+',?\s?([^\)]*)?\)/, "\\1(\\2)")
      end
      super
    end

    def format_colspec(colspec)
      if simple
        super.gsub(/CAST\('?([^,']*)'?,\s?'.*?'\)/, "\\1")
      elsif colspec[:value]
        super.gsub(/value\:\s/, "")
      else
        super
      end
    end

    def schema_limit(column)
      return nil if column.type == :float
      super
    end

    def schema_unsigned(column)
      return nil unless column.type == :integer && !simple
      (column.sql_type =~ /(Nullable)?\(?UInt\d+\)?/).nil? ? false : nil
    end

    def schema_array(column)
      (column.sql_type =~ /Array?\(/).nil? ? nil : true
    end

    def schema_type(column)
      return :column if [:enum8, :enum16].include?(column.type) || column.sql_type =~ /Array/
      super
    end

    def prepare_column_options(column)
      spec = {}
      spec[:unsigned] = schema_unsigned(column)

      if column.type == :map
        spec[:key_type] = "\"#{column.key_type}\""
        spec[:value_type] = "\"#{column.value_type}\""
      end

      if [:enum8, :enum16].include?(column.type) || column.sql_type =~ /Array/
        spec[:value] = "\"#{column.sql_type}\""
      end

      spec.merge(super).compact
    end

    def index_parts(index)
      idx = index.match(/^INDEX (?<name>\S+) (?<expr>.*?) TYPE (?<type>.*?) GRANULARITY (?<granularity>\d+)$/)
      index_parts = [
        format_index_parts(idx['expr']),
        "name: #{format_index_parts(idx['name'])}",
        "type: #{format_index_parts(idx['type'])}",
      ]
      index_parts << "granularity: #{idx['granularity']}" if idx['granularity']
      index_parts
    end

    def extract_nested_columns(columns)
      extracted = {}

      columns.select { |c| c.sql_type =~ /Array/ && c.name =~/\./ }.each do |column|
        key = column.name.split('.').first
        extracted[key] ||= []
        extracted[key] << column
      end

      extracted
    end
  end
end

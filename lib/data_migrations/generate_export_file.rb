# frozen_string_literal: true

module DataMigrations
  module GenerateExportFile
    HEADERS = ['File Name', 'Template Name', 'Template ID'].freeze

    module_function

    def call(results)
      workbook = RubyXL::Workbook.new
      worksheet = workbook[0]
      worksheet.sheet_name = 'Migration Results'

      HEADERS.each_with_index do |header, col_index|
        worksheet.add_cell(0, col_index, header)
      end

      results.each_with_index do |result, row_index|
        worksheet.add_cell(row_index + 1, 0, result['file_name'])
        worksheet.add_cell(row_index + 1, 1, result['template_name'])
        worksheet.add_cell(row_index + 1, 2, result['template_id'])
      end

      workbook.stream.string
    end
  end
end

# frozen_string_literal: true

module TimeUtils
  MONTH_FORMATS = {
    'M' => '%-m',
    'MM' => '%m',
    'MMM' => '%b',
    'MMMM' => '%B'
  }.freeze

  DAY_FORMATS = {
    'D' => '%-d',
    'DD' => '%d'
  }.freeze

  YEAR_FORMATS = {
    'YYYY' => '%Y',
    'YYY' => '%Y',
    'YY' => '%y'
  }.freeze

  DEFAULT_DATE_FORMAT_US = 'MM/DD/YYYY'
  DEFAULT_DATE_FORMAT = 'DD/MM/YYYY'

  US_TIMEZONES = %w[EST CST MST PST HST AKDT].freeze

  module_function

  def timezone_abbr(timezone, time = Time.current)
    tz_info = TZInfo::Timezone.get(
      ActiveSupport::TimeZone::MAPPING[timezone] || timezone || 'UTC'
    )

    tz_info.abbreviation(time)
  end

  def parse_time_value(value)
    if value.is_a?(Integer)
      Time.zone.at(value.to_s.first(10).to_i)
    elsif value.present?
      Time.zone.parse(value)
    end
  end

  def parse_date_string(string, pattern)
    pattern = pattern.sub(/Y+/, YEAR_FORMATS)
                     .sub(/M+/, MONTH_FORMATS)
                     .sub(/D+/, DAY_FORMATS)

    Date.strptime(string, pattern)
  end

  # Parse a stored date value into a Date, or nil when it can't be understood.
  #
  # `Date.parse` reads slash-separated dates day-first ("08/05/2026" => May 8),
  # but form values are stored month-first (MM/DD/YYYY), so ambiguous values are
  # resolved using the field's display pattern instead of Date.parse defaults.
  def parse_date_value(value, pattern = nil)
    return nil if value.nil?
    return value if value.is_a?(Date) && !value.is_a?(DateTime)
    return value.to_date if value.is_a?(Time) || value.is_a?(DateTime)
    return Time.zone.at(value.to_s.first(10).to_i).to_date if value.is_a?(Integer)

    string = value.to_s.strip

    return nil if string.blank?

    # Year first and therefore unambiguous: 2026-08-05, 2026/08/05, "2026 08 05".
    if (match = string.match(%r{\A(\d{4})[-/. ]+(\d{1,2})[-/. ]+(\d{1,2})\z}))
      return build_date(match[1], match[2], match[3])
    end

    # ISO datetime: use the date portion so the timezone can't shift the day.
    if (match = string.match(%r{\A(\d{4})-(\d{1,2})-(\d{1,2})[T ]}))
      return build_date(match[1], match[2], match[3])
    end

    # Compact ISO: 20260805
    if (match = string.match(/\A(\d{4})(\d{2})(\d{2})\z/))
      return build_date(match[1], match[2], match[3])
    end

    # Ambiguous numeric date with a 4-digit year: 08/05/2026, 08-05-2026, 08.05.2026
    if (match = string.match(%r{\A(\d{1,2})([-/. ]+)(\d{1,2})[-/. ]+(\d{4})\z}))
      first = match[1].to_i
      second = match[3].to_i

      day_first = day_before_month?(pattern, match[2])
      day_first = true if first > 12
      day_first = false if second > 12

      return day_first ? build_date(match[4], second, first) : build_date(match[4], first, second)
    end

    Date.parse(string)
  rescue ArgumentError, TypeError
    nil
  end

  def format_date_string(string, format, locale)
    format = format.upcase if format

    format ||= locale.to_s.ends_with?('US') ? DEFAULT_DATE_FORMAT_US : DEFAULT_DATE_FORMAT

    date = parse_date_value(string, format)

    return string if date.nil?

    i18n_format = format.sub(/D+/) { DAY_FORMATS[format[/D+/]] }
                        .sub(/M+/) { MONTH_FORMATS[format[/M+/]] }
                        .sub(/Y+/) { YEAR_FORMATS[format[/Y+/]] }

    I18n.l(date, format: i18n_format, locale:)
  rescue ArgumentError, TypeError
    string
  end

  # Decide whether the day comes before the month for an ambiguous value, based
  # on the display pattern. Dotted dates default to day-first (DD.MM.YYYY).
  def day_before_month?(pattern, separator = nil)
    upcased = pattern.to_s.upcase
    day_index = upcased.index('D')
    month_index = upcased.index('M')

    return day_index < month_index if day_index && month_index

    separator.to_s.include?('.')
  end

  def build_date(year, month, day)
    Date.new(year.to_i, month.to_i, day.to_i)
  rescue ArgumentError, TypeError
    nil
  end
end

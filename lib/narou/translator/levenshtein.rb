# frozen_string_literal: true

module Narou
  module Translator
    module Levenshtein
      def self.distance(str1, str2)
        s = str1.chars
        t = str2.chars
        n = s.length
        m = t.length

        return m if n == 0
        return n if m == 0

        d = Array.new(n + 1) { Array.new(m + 1) }

        (0..n).each { |i| d[i][0] = i }
        (0..m).each { |j| d[0][j] = j }

        (1..n).each do |i|
          (1..m).each do |j|
            cost = (s[i - 1] == t[j - 1]) ? 0 : 1
            d[i][j] = [
              d[i - 1][j] + 1,      # deletion
              d[i][j - 1] + 1,      # insertion
              d[i - 1][j - 1] + cost # substitution
            ].min
          end
        end

        d[n][m]
      end
    end
  end
end

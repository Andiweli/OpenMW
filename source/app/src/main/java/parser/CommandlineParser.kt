/*
    Copyright (C) 2016 sandstranger
    Copyright (C) 2018 Ilya Zhuravlev

    This file is part of OpenMW-Android.

    OpenMW-Android is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    OpenMW-Android is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with OpenMW-Android.  If not, see <https://www.gnu.org/licenses/>.
*/

package parser

import java.util.ArrayList

/** Parses the launcher command line while preserving quoted arguments. */
class CommandlineParser(data: String) {
    private val args = ArrayList<String>()
    val argv: Array<String>

    val argc: Int
        get() = args.size

    init {
        args.add("openmw")

        if (data.contains("--")) {
            args.addAll(tokenize(data))
        }

        argv = args.toTypedArray()
    }

    private fun tokenize(input: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var quote: Char? = null
        var tokenStarted = false
        var index = 0

        fun flush() {
            if (tokenStarted) {
                result += current.toString()
                current.setLength(0)
                tokenStarted = false
            }
        }

        while (index < input.length) {
            val char = input[index]

            if (quote != null) {
                when {
                    char == quote -> {
                        quote = null
                        tokenStarted = true
                        index += 1
                    }
                    char == '\\' && index + 1 < input.length &&
                        (input[index + 1] == quote || input[index + 1] == '\\') -> {
                        current.append(input[index + 1])
                        tokenStarted = true
                        index += 2
                    }
                    else -> {
                        current.append(char)
                        tokenStarted = true
                        index += 1
                    }
                }
                continue
            }

            when {
                char.isWhitespace() -> {
                    flush()
                    index += 1
                }
                char == '"' || char == '\'' -> {
                    quote = char
                    tokenStarted = true
                    index += 1
                }
                char == '\\' && index + 1 < input.length &&
                    (input[index + 1].isWhitespace() || input[index + 1] == '"' ||
                        input[index + 1] == '\'' || input[index + 1] == '\\') -> {
                    current.append(input[index + 1])
                    tokenStarted = true
                    index += 2
                }
                else -> {
                    current.append(char)
                    tokenStarted = true
                    index += 1
                }
            }
        }

        // An unmatched quote is treated as extending to the end of input.
        flush()
        return result
    }
}

#include <QtTest/QtTest>
#include <string>
#include <vector>
#include <cmath>

#include "utils.h"

// Define extern variables required by utils.cpp
std::wstring LIBGEN_ADDRESS = L"";
std::wstring GOOGLE_SCHOLAR_ADDRESS = L"";
std::ofstream LOG_FILE;
int STATUS_BAR_FONT_SIZE = 0;
float STATUS_BAR_COLOR[3] = {0, 0, 0};
float STATUS_BAR_TEXT_COLOR[3] = {1, 1, 1};
float UI_SELECTED_TEXT_COLOR[3] = {1, 1, 1};
float UI_SELECTED_BACKGROUND_COLOR[3] = {0, 0, 1};
bool NUMERIC_TAGS = false;

class TestUtils : public QObject {
    Q_OBJECT

private slots:
    // mod() tests
    void test_mod_positive() {
        QCOMPARE(mod(7, 3), 1);
        QCOMPARE(mod(10, 5), 0);
        QCOMPARE(mod(0, 3), 0);
    }

    void test_mod_negative() {
        QCOMPARE(mod(-1, 3), 2);
        QCOMPARE(mod(-7, 3), 2);
        QCOMPARE(mod(-3, 3), 0);
    }

    // range_intersects() tests
    void test_range_intersects_overlapping() {
        QVERIFY(range_intersects(0.0f, 5.0f, 3.0f, 8.0f));
        QVERIFY(range_intersects(3.0f, 8.0f, 0.0f, 5.0f));
    }

    void test_range_intersects_touching() {
        QVERIFY(range_intersects(0.0f, 5.0f, 5.0f, 10.0f));
    }

    void test_range_intersects_non_overlapping() {
        QVERIFY(!range_intersects(0.0f, 3.0f, 5.0f, 8.0f));
        QVERIFY(!range_intersects(5.0f, 8.0f, 0.0f, 3.0f));
    }

    void test_range_intersects_contained() {
        QVERIFY(range_intersects(0.0f, 10.0f, 3.0f, 5.0f));
        QVERIFY(range_intersects(3.0f, 5.0f, 0.0f, 10.0f));
    }

    // to_lower() tests
    void test_to_lower_basic() {
        QCOMPARE(to_lower(L"HELLO"), std::wstring(L"hello"));
        QCOMPARE(to_lower(L"Hello World"), std::wstring(L"hello world"));
    }

    void test_to_lower_already_lowercase() {
        QCOMPARE(to_lower(L"hello"), std::wstring(L"hello"));
    }

    void test_to_lower_empty() {
        QCOMPARE(to_lower(L""), std::wstring(L""));
    }

    // reverse_wstring() tests
    void test_reverse_wstring() {
        QCOMPARE(reverse_wstring(L"hello"), std::wstring(L"olleh"));
        QCOMPARE(reverse_wstring(L"a"), std::wstring(L"a"));
        QCOMPARE(reverse_wstring(L""), std::wstring(L""));
    }

    // manhattan_distance() tests
    void test_manhattan_distance() {
        QCOMPARE(manhattan_distance(0.0f, 0.0f, 3.0f, 4.0f), 7.0f);
        QCOMPARE(manhattan_distance(1.0f, 2.0f, 1.0f, 2.0f), 0.0f);
        QCOMPARE(manhattan_distance(-1.0f, -1.0f, 1.0f, 1.0f), 4.0f);
    }

    // is_string_numeric() tests
    void test_is_string_numeric_valid() {
        QVERIFY(is_string_numeric(L"123"));
        QVERIFY(is_string_numeric(L"0"));
        QVERIFY(is_string_numeric(L"-42"));
    }

    void test_is_string_numeric_invalid() {
        QVERIFY(!is_string_numeric(L""));
        QVERIFY(!is_string_numeric(L"abc"));
        QVERIFY(!is_string_numeric(L"12.3"));
        QVERIFY(!is_string_numeric(L"12a"));
    }

    // is_string_numeric_float() tests
    void test_is_string_numeric_float_valid() {
        QVERIFY(is_string_numeric_float(L"1.5"));
        QVERIFY(is_string_numeric_float(L"-3.14"));
        QVERIFY(is_string_numeric_float(L"42"));
    }

    void test_is_string_numeric_float_invalid() {
        QVERIFY(!is_string_numeric_float(L""));
        QVERIFY(!is_string_numeric_float(L"abc"));
        QVERIFY(!is_string_numeric_float(L"1.2.3"));
    }

    // split_path() tests
    void test_split_path() {
        std::vector<std::wstring> result;
        split_path(L"/home/user/document.pdf", result);
        QCOMPARE(result.size(), (size_t)3);
        QCOMPARE(result[0], std::wstring(L"home"));
        QCOMPARE(result[1], std::wstring(L"user"));
        QCOMPARE(result[2], std::wstring(L"document.pdf"));
    }

    void test_split_path_single() {
        std::vector<std::wstring> result;
        split_path(L"file.txt", result);
        QCOMPARE(result.size(), (size_t)1);
        QCOMPARE(result[0], std::wstring(L"file.txt"));
    }

    // concatenate_path() tests
    void test_concatenate_path() {
        std::wstring result = concatenate_path(L"/home/user", L"file.txt");
        QCOMPARE(result, std::wstring(L"/home/user/file.txt"));
    }

    void test_concatenate_path_trailing_slash() {
        std::wstring result = concatenate_path(L"/home/user/", L"file.txt");
        QCOMPARE(result, std::wstring(L"/home/user/file.txt"));
    }

    void test_concatenate_path_empty_prefix() {
        std::wstring result = concatenate_path(L"", L"file.txt");
        QCOMPARE(result, std::wstring(L"file.txt"));
    }

    // truncate_string() tests
    void test_truncate_string_short() {
        QCOMPARE(truncate_string(L"hi", 10), std::wstring(L"hi"));
    }

    void test_truncate_string_long() {
        std::wstring result = truncate_string(L"a very long string", 10);
        QCOMPARE(result, std::wstring(L"a very..."));
    }

    // get_f_key() tests
    void test_get_f_key() {
        QCOMPARE(get_f_key(L"<f1>"), 1);
        QCOMPARE(get_f_key(L"<f12>"), 12);
        QCOMPARE(get_f_key(L"f5"), 5);
    }

    void test_get_f_key_invalid() {
        QCOMPARE(get_f_key(L"<abc>"), 0);
    }

    // utf8 encode/decode roundtrip test
    void test_utf8_roundtrip() {
        std::wstring original = L"Hello World";
        std::string encoded = utf8_encode(original);
        std::wstring decoded = utf8_decode(encoded);
        QCOMPARE(decoded, original);
    }

    // get_page_formatted_string() tests
    void test_get_page_formatted_string() {
        QCOMPARE(get_page_formatted_string(1), std::wstring(L"[ 1 ]"));
        QCOMPARE(get_page_formatted_string(42), std::wstring(L"[ 42 ]"));
    }

    // parse_search_command() tests
    void test_parse_search_command_ranged() {
        int begin, end;
        std::wstring text;
        bool result = parse_search_command(L"<5,10>search text", &begin, &end, &text);
        QVERIFY(result);
        QCOMPARE(begin, 5);
        QCOMPARE(end, 10);
        QCOMPARE(text, std::wstring(L"search text"));
    }

    void test_parse_search_command_plain() {
        int begin, end;
        std::wstring text;
        bool result = parse_search_command(L"search text", &begin, &end, &text);
        QVERIFY(!result);
        QCOMPARE(text, std::wstring(L"search text"));
    }

    // strip_string() tests
    void test_strip_string() {
        std::wstring input = L"  hello  ";
        QCOMPARE(strip_string(input), std::wstring(L"hello"));
    }

    void test_strip_string_no_whitespace() {
        std::wstring input = L"hello";
        QCOMPARE(strip_string(input), std::wstring(L"hello"));
    }

    void test_strip_string_empty() {
        std::wstring input = L"";
        QCOMPARE(strip_string(input), std::wstring(L""));
    }

    void test_strip_string_only_whitespace() {
        std::wstring input = L"   ";
        QCOMPARE(strip_string(input), std::wstring(L""));
    }

    // split_key_string() tests
    void test_split_key_string() {
        std::vector<std::wstring> result;
        split_key_string(L"a+b+c", L"+", result);
        QCOMPARE(result.size(), (size_t)3);
        QCOMPARE(result[0], std::wstring(L"a"));
        QCOMPARE(result[1], std::wstring(L"b"));
        QCOMPARE(result[2], std::wstring(L"c"));
    }

    void test_split_key_string_no_delimiter() {
        std::vector<std::wstring> result;
        split_key_string(L"abc", L"+", result);
        QCOMPARE(result.size(), (size_t)1);
        QCOMPARE(result[0], std::wstring(L"abc"));
    }

    // lcs() tests
    void test_lcs() {
        QCOMPARE(lcs("ABCBDAB", "BDCAB", 7, 5), 4);
        QCOMPARE(lcs("ABC", "ABC", 3, 3), 3);
        QCOMPARE(lcs("ABC", "DEF", 3, 3), 0);
    }

    // get_aplph_tag() / get_index_from_tag() roundtrip
    void test_tag_roundtrip() {
        std::string tag = get_aplph_tag(0, 100);
        int index = get_index_from_tag(tag);
        QCOMPARE(index, 0);

        tag = get_aplph_tag(5, 100);
        index = get_index_from_tag(tag);
        QCOMPARE(index, 5);
    }

    // command_requires_text() tests
    void test_command_requires_text() {
        QVERIFY(command_requires_text(L"run %5 now"));
        QVERIFY(command_requires_text(L"run command_text now"));
        QVERIFY(!command_requires_text(L"simple_command"));
    }

    // command_requires_rect() tests
    void test_command_requires_rect() {
        QVERIFY(command_requires_rect(L"crop %{selected_rect} done"));
        QVERIFY(!command_requires_rect(L"simple_command"));
    }

    // parse_command_string() tests
    void test_parse_command_string_with_data() {
        std::string name;
        std::wstring data;
        parse_command_string(L"goto_page(42)", name, data);
        QCOMPARE(name, std::string("goto_page"));
        QCOMPARE(data, std::wstring(L"42"));
    }

    void test_parse_command_string_no_data() {
        std::string name;
        std::wstring data;
        parse_command_string(L"quit", name, data);
        QCOMPARE(name, std::string("quit"));
        QCOMPARE(data, std::wstring(L""));
    }

    // hexademical_to_normalized_color() tests
    void test_hex_to_normalized_color() {
        float color[3];
        hexademical_to_normalized_color(L"#ff0080", color, 3);
        QVERIFY(std::abs(color[0] - 1.0f) < 0.01f);
        QVERIFY(std::abs(color[1] - 0.0f) < 0.01f);
        QVERIFY(std::abs(color[2] - 0.502f) < 0.01f);
    }

    // Vec tests
    void test_vec_default_constructor() {
        fvec2 v;
        QCOMPARE(v[0], 0.0f);
        QCOMPARE(v[1], 0.0f);
    }

    void test_vec_value_constructor() {
        fvec2 v(3.0f, 4.0f);
        QCOMPARE(v[0], 3.0f);
        QCOMPARE(v[1], 4.0f);
    }

    void test_vec_addition() {
        fvec2 a(1.0f, 2.0f);
        fvec2 b(3.0f, 4.0f);
        fvec2 c = a + b;
        QCOMPARE(c[0], 4.0f);
        QCOMPARE(c[1], 6.0f);
    }

    void test_vec_subtraction() {
        fvec2 a(5.0f, 7.0f);
        fvec2 b(2.0f, 3.0f);
        fvec2 c = a - b;
        QCOMPARE(c[0], 3.0f);
        QCOMPARE(c[1], 4.0f);
    }

    void test_vec_division() {
        fvec2 a(6.0f, 8.0f);
        fvec2 c = a / 2.0f;
        QCOMPARE(c[0], 3.0f);
        QCOMPARE(c[1], 4.0f);
    }

    // serialize/deserialize string array roundtrip
    void test_serialize_deserialize_string_array() {
        QStringList original;
        original << "hello" << "world" << "test";
        QByteArray serialized = serialize_string_array(original);
        QStringList deserialized = deserialize_string_array(serialized);
        QCOMPARE(deserialized, original);
    }

    void test_serialize_deserialize_empty_array() {
        QStringList original;
        QByteArray serialized = serialize_string_array(original);
        QStringList deserialized = deserialize_string_array(serialized);
        QCOMPARE(deserialized, original);
    }

    // is_string_titlish() tests
    void test_is_string_titlish() {
        QVERIFY(is_string_titlish(L"1.2.3 Introduction to Algorithms"));
        QVERIFY(is_string_titlish(L"IV.2 Section Title Here"));
        QVERIFY(!is_string_titlish(L"Hi"));
        QVERIFY(!is_string_titlish(L"no numbered prefix at all here"));
    }

    // split_whitespace() tests
    void test_split_whitespace() {
        std::vector<std::wstring> result = split_whitespace(L"hello world  test");
        QCOMPARE(result.size(), (size_t)3);
        QCOMPARE(result[0], std::wstring(L"hello"));
        QCOMPARE(result[1], std::wstring(L"world"));
        QCOMPARE(result[2], std::wstring(L"test"));
    }

    void test_split_whitespace_empty() {
        std::vector<std::wstring> result = split_whitespace(L"");
        QCOMPARE(result.size(), (size_t)0);
    }
};

QTEST_MAIN(TestUtils)
#include "test_utils.moc"

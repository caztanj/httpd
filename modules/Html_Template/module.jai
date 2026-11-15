html_template :: (template: string, values: Table(string, string), escape := true) -> string {
    return html_template(template, values, (key: string, values: Table(string, string)) -> string {
        found, value := table_find(*values, key);
        if !found return tprint("<'%' NOT FOUND>", key);
        return value;
    }, escape = escape);
}

html_template :: (template: string, user_data: $T, fn: (string, T) -> string, escape := true) -> string {
    b: String_Builder;
    b.allocator = temp;

    current := template;
    while true {
        start := find_index_from_left(current, "{{");
        if start == -1 {
            append(*b, current);
            break;
        }

        end := find_index_from_left(current, "}}", start);
        if end == -1 {
            append(*b, current);
            break;
        }

        before := slice(current, 0, start);
        middle := trim(slice(current, start + 2, end - start - 2));

        parts := split(middle, "|");
        var_name := trim(parts[0]);

        value := fn(var_name, user_data);

        for i: 1..parts.count-1 {
            filter_name := trim(parts[i]);
            found_filter, filter_fn := table_find(*registered_filters, filter_name);
            if found_filter {
                value = filter_fn(value);
            }
        }

        append(*b, before);
        append(*b, ifx escape safe_html(value,, temp) else value);

        current = slice(current, end + 2, current.count - end - 2);
    }

    return builder_to_string(*b);
}

html_template_from_file :: (path: string, values: Table(string, string), escape := true) -> error: bool, string {
    template, success := read_entire_file(path);
    if !success return true, "";

    return false, html_template(template, values, escape = escape);
}

html_template_from_file :: (path: string, user_data: $T, fn: (string, T) -> string, escape := true) -> error: bool, string {
    template, success := read_entire_file(path);
    if !success return true, "";

    return false, html_template(template, user_data, fn, escape = escape);
}

html_environment_template :: (template: string, escape := true, delimiter := "HERE") -> string #expand {
    return #insert -> string {
        b: String_Builder;
        b.allocator = temp;

        e: String_Builder;
        e.allocator = temp;

        escape_and_append :: (b: *String_Builder, e: *String_Builder, s: string) {
            current := s;
            while true {
                idx := find_index_from_left(current, "%");
                if idx == -1 {
                    append(b, current);
                    break;
                }
                append(b, slice(current, 0, idx + 1));
                append(e, "\"%\", ");
                current = slice(current, idx + 1, current.count - idx - 1);
            }
        }

        current := template;
        while true {
            start := find_index_from_left(current, "{{");
            if start == -1 {
                escape_and_append(*b, *e, current);
                break;
            }

            end := find_index_from_left(current, "}}", start);
            if end == -1 {
                escape_and_append(*b, *e, current);
                break;
            }

            before := slice(current, 0, start);
            middle := trim(slice(current, start + 2, end - start - 2));

            escape_and_append(*b, *e, before);

            append(*b, "%");
            print_to_builder(*e, "`%, ", middle);

            current = slice(current, end + 2, current.count - end - 2);
        }

        first  := builder_to_string(*b,, temp);
        second := builder_to_string(*e,, temp);

        if second == "" {
            return tprint("#string %\n%\n%", delimiter, first, delimiter);
        }

        second = slice(second, 0, second.count - 2);

        return tprint("tprint(#string %\n%\n%, %);", delimiter, first, delimiter, second);
    };
}

safe_html :: (attribute: string) -> string {
    needs_escape := false;
    for i: 0..attribute.count-1 {
        c := attribute[i];
        if c == 0 || c == "\"" || c == "&" || c == "'" || c == "+" || c == "<" || c == ">" {
            needs_escape = true;
            break;
        }
    }

    if !needs_escape return attribute;

    builder: String_Builder;
    builder.allocator = temp;

    last_index := 0;
    for i: 0..attribute.count-1 {
        c := attribute[i];
        if c == 0 || c == "\"" || c == "&" || c == "'" || c == "+" || c == "<" || c == ">" {
            if i > last_index {
                append(*builder, slice(attribute, last_index, i - last_index));
            }

            if c == {
                case 0;    append(*builder, "\xef\xbf\xbd");
                case "\""; append(*builder, "&#34;");
                case "&";  append(*builder, "&amp;");
                case "'";  append(*builder, "&#39;");
                case "+";  append(*builder, "&#43;");
                case "<";  append(*builder, "&lt;");
                case ">";  append(*builder, "&gt;");
            }

            last_index = i + 1;
        }
    }

    if last_index < attribute.count {
        append(*builder, slice(attribute, last_index, attribute.count - last_index));
    }

    return builder_to_string(*builder);
}

register_filter :: (name: string, filter: Filter_Function) {
    table_set(*registered_filters, name, filter);
}

Filter_Function :: #type (string) -> string;

registered_filters: Table(string, Filter_Function);

#scope_module

#import "Basic";
#import "File";
#import "Hash_Table";
#import "String";
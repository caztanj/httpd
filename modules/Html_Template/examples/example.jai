main :: () {
    register_filter("uppercase", (s: string) -> string {
        return to_upper_copy(s,, temp);
    });

    function_interface();
    print("\n");
    table_interface();
    print("\n");
    environment_interface();
}

function_interface :: () {
    s := html_template(TEMPLATE, null, (key: string, user_data: *void) -> string {
        if key == {
            case "content";
                return "Some content";

            case "give_me_a_thing";
                return give_me_a_thing();

            case;
                return "";
        }
    });

    print("Function Interface:\n");
    print("%", s);
}

table_interface :: () {
    t: Table(string, string);
    table_set(*t, "content", "Content");

    s := html_template(TEMPLATE, t);

    print("Table Interface:\n");
    print("%", s);
}

environment_interface :: () {
    more := "h1 { font-size: 14em; }";

    css := html_environment_template(#string CSS
body {
    margin: 0;
}

code, pre {
    margin: 0;
    min-height: 100vh;
    height: 100%;
}

{{ more }}
    CSS);

    print("Environment Interface:\n");
    print("%", css);
}

give_me_a_thing :: () -> string {
    return "A thing";
}

#run {
    set_build_options_dc(.{ do_output = false });
    main();
}

TEMPLATE :: #string HTML
<html>
    <head>
    </head>
    <body>
        {{ content }}
        {{ give_me_a_thing }}
        {{ content | uppercase }}
    </body>
</html>
HTML

#import "Basic";
#import "Compiler";
#import "Hash_Table";
#import "String";

#import,file "../module.jai";
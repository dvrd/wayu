import argv
import envoy
import gleam/io
import gleam/string
import gleam/result

pub fn main() {
  case argv.load().arguments {
    ["get", name] -> get(string.uppercase(name))
    _ -> io.println("Usage: vars get <name>")
  }
}

fn get(name: String) -> Nil {
  let value =
    envoy.get(name)
    |> result.unwrap("")
  io.println(format_pair(name, value))
}

fn format_pair(name: String, value: String) -> String {
  name <> "=" <> value
}

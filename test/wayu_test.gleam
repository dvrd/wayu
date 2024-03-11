import gleeunit
import gleeunit/should
import wayu/internal

pub fn main() {
  gleeunit.main()
}

pub fn format_pair_test() {
  internal.format_pair("hello", "world")
  |> should.equal("hello=world")
}

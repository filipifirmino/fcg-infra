resource "aws_dynamodb_table" "game_reviews" {
  name         = var.reviews_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "gameId"
  range_key    = "userId"

  attribute {
    name = "gameId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }
}

resource "aws_secretsmanager_secret" "app" {
  for_each = toset(var.secret_names)

  name                    = each.value
  recovery_window_in_days = 0
}

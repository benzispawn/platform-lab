terraform {
  backend "s3" {
    bucket = "platform-lab-bucket"
    key    = "s3:somepath"
    region = "sa-east-1"
  }
}

resource "aws_vpc" "platform_lab_vpc" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = "default"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "${var.project}-vpc"
  }
}

resource "aws_internet_gateway" "platform_lab_vpc" {
  vpc_id = aws_vpc.platform_lab_vpc.id
  tags = {
    Name = "${var.project}-gateway"
  }
}

resource "aws_subnet" "platform_lab_vpc_public_1" {
  vpc_id            = aws_vpc.platform_lab_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "${var.project}-public-${data.aws_availability_zones.available.names[0]}"
  }
}

resource "aws_subnet" "platform_lab_vpc_public_2" {
  vpc_id            = aws_vpc.platform_lab_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 1)
  availability_zone = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "${var.project}-public-${data.aws_availability_zones.available.names[1]}"
  }
}

resource "aws_subnet" "platform_lab_vpc_private_1" {
  vpc_id            = aws_vpc.platform_lab_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 2)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "${var.project}-private-${data.aws_availability_zones.available.names[0]}"
  }
}

resource "aws_subnet" "platform_lab_vpc_private_2" {
  vpc_id            = aws_vpc.platform_lab_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 3)
  availability_zone = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "${var.project}-private-${data.aws_availability_zones.available.names[1]}"
  }
}

resource "aws_route_table" "platform_lab_vpc_route_public" {
  vpc_id = aws_vpc.platform_lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.platform_lab_vpc.id
  }
  tags = {
    Name = "${var.project}-route-public"
  }
}

resource "aws_route_table" "platform_lab_vpc_route_private" {
  vpc_id = aws_vpc.platform_lab_vpc.id
  tags = {
    Name = "${var.project}-route-private"
  }
}

resource "aws_route_table_association" "platform_lab_vpc_association_private_1" {
  subnet_id      = aws_subnet.platform_lab_vpc_private_1.id
  route_table_id = aws_route_table.platform_lab_vpc_route_private.id
}

resource "aws_route_table_association" "platform_lab_vpc_association_private_2" {
  subnet_id      = aws_subnet.platform_lab_vpc_private_2.id
  route_table_id = aws_route_table.platform_lab_vpc_route_private.id
}

resource "aws_route_table_association" "platform_lab_vpc_association_public_1" {
  subnet_id      = aws_subnet.platform_lab_vpc_public_1.id
  route_table_id = aws_route_table.platform_lab_vpc_route_public.id
}

resource "aws_route_table_association" "platform_lab_vpc_association_public_2" {
  subnet_id      = aws_subnet.platform_lab_vpc_public_2.id
  route_table_id = aws_route_table.platform_lab_vpc_route_public.id
}

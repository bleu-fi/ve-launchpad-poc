owner: address


@external
def __init__(_owner: address):
    self.owner = _owner


@external
def getOwner() -> address:
    return self.owner
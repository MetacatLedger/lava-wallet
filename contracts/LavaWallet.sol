pragma solidity ^0.4.18;

import "./ECRecovery.sol";
import "./SafeMath.sol";


contract ERC20Interface {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}


//wEth interface
contract WrapperInterface
{
  function() public payable;
  function deposit() public payable ;
  function withdraw(uint wad) public;
  function totalSupply() public view returns (uint);
  function approve(address guy, uint wad) public returns (bool);
  function transfer(address dst, uint wad) public returns (bool);
  function transferFrom(address src, address dst, uint wad);


  event  Approval(address indexed src, address indexed guy, uint wad);
  event  Transfer(address indexed src, address indexed dst, uint wad);
  event  Deposit(address indexed dst, uint wad);
  event  Withdrawal(address indexed src, uint wad);

}





contract LavaWallet {


  using SafeMath for uint;

  // balances[tokenContractAddress][EthereumAccountAddress] = 0
   mapping(address => mapping (address => uint256)) balances;

   //token => owner => spender : amount
   mapping(address => mapping (address => mapping (address => uint256))) allowed;

   mapping(bytes32 => uint256) burnedSignatures;


  event Deposit(address token, address user, uint amount, uint balance);
  event Withdraw(address token, address user, uint amount, uint balance);
  event Transfer(address indexed from, address indexed to,address token, uint tokens);
  event Approval(address indexed tokenOwner, address indexed spender,address token, uint tokens);

  function LavaWallet() public  {

  }


  //do not allow ether to enter
  function() public payable {
      revert();
  }


  //send Ether into this method, it gets wrapped and then deposited in this contract as a token balance assigned to the sender
  function depositAndWrap(address wrappingContract) public payable
  {
    //convert the eth into wEth

    //send this payable ether into the wrapping contract
    wrappingContract.transfer(msg.value);

    //send the tokens from the wrapping contract to here
    WrapperInterface(wrappingContract).transfer(this, msg.value);

    balances[wrappingContract][msg.sender] = balances[wrappingContract][msg.sender].add(msg.value);

    assert(this.balance == 0); //make sure it is not a faulty wrapping contract

    Deposit(wrappingContract, msg.sender, msg.value, balances[wrappingContract][msg.sender]);
  }

  //when this contract has control of wrapped eth, this is a way to easily withdraw it as ether
  function unwrapAndWithdraw(address token, uint256 tokens) public
  {
      //transfer the tokens into the wrapping contract which is also the token contract
      transfer(token,token,tokens);

      WrapperInterface(token).withdraw(tokens);

      //send ether to the token-sender
      msg.sender.transfer(tokens);

      assert(this.balance == 0); //make sure it is not a faulty wrapping contract

      Withdraw(token, msg.sender, tokens, balances[token][msg.sender]);

  }


   //remember you need pre-approval for this - nice with ApproveAndCall
  function depositToken(address from, address token, uint256 tokens) public returns (bool)
  {
    ///  if(msg.sender != token) revert(); //must come from ApproveAndCall
      if(token <= 0) revert(); //need to deposit some tokens

      //we already have approval so lets do a transferFrom - transfer the tokens into this contract
      ERC20Interface(token).transferFrom(from, this, tokens);
      balances[token][from] = balances[token][from].add(tokens);

      Deposit(token, from, tokens, balances[token][from]);

      return true;
  }

  function withdrawToken(address token, uint256 tokens) {
    if(token <= 0) revert();
    if (balances[token][msg.sender] < tokens) revert();

    balances[token][msg.sender] = balances[token][msg.sender].sub(tokens);

    ERC20Interface(token).transfer(msg.sender, tokens);

    Withdraw(token, msg.sender, tokens, balances[token][msg.sender]);
  }

  function balanceOf(address token,address user) public constant returns (uint) {
       return balances[token][user];
   }

 function transfer(address to, address token, uint tokens) public returns (bool success) {
      balances[token][msg.sender] = balances[token][msg.sender].sub(tokens);
      balances[token][to] = balances[token][to].add(tokens);
      Transfer(msg.sender, token, to, tokens);
      return true;
  }

   function approve(address spender, address token, uint tokens) public returns (bool success) {
       allowed[token][msg.sender][spender] = tokens;
       Approval(msg.sender, token, spender, tokens);
       return true;
   }


   function transferFrom( address from, address to,address token,  uint tokens) public returns (bool success) {
       balances[token][from] = balances[token][from].sub(tokens);
       allowed[token][from][msg.sender] = allowed[token][from][msg.sender].sub(tokens);
       balances[token][to] = balances[token][to].add(tokens);
       Transfer(token, from, to, tokens);
       return true;
   }

   //allows transfer without approval as long as you get an EC signature
  function transferFromWithSignature(address from, uint256 tokens, address token, uint256 checkNumber, bytes32 sigHash, bytes signature) public returns (bool)
  {
      //check to make sure that signature == ecrecover signature

      address recoveredSignatureSigner = ECRecovery.recover(sigHash,signature);

      //make sure the signer is the depositor of the tokens
      if(from != recoveredSignatureSigner) revert();

      //make sure the signed hash incorporates the token recipient, quantity to withdraw, and the check number
      bytes32 sigDigest = keccak256(msg.sender, tokens, token, checkNumber);

      //make sure this signature has never been used
      uint burnedSignature = burnedSignatures[sigDigest];
      burnedSignatures[sigDigest] = 0x1; //spent
      if(burnedSignature != 0x0 ) revert();

      //make sure the data being signed (sigHash) really does match the msg.sender, tokens, and checkNumber
      if(sigDigest != sigHash) revert();

      //make sure the token-depositor has enough tokens in escrow
      if(balanceOf(token, from) < tokens) revert();

      //finally, transfer the tokens out of this contracts escrow to msg.sender
      balances[token][from].sub(tokens);
      ERC20Interface(token).transfer(msg.sender, tokens);


      return true;
  }



     function signatureBurned(bytes32 digest) public view returns (bool)
     {
       return (burnedSignatures[digest] != 0x0);
     }


     function burnSignature(address to, uint256 tokens, address token, uint256 checkNumber, bytes32 sigHash, bytes signature) public returns (bool)
     {
         address recoveredSignatureSigner = ECRecovery.recover(sigHash,signature);

         //maker sure the invalidator is the signer
         if(recoveredSignatureSigner != msg.sender) revert();

         bytes32 sigDigest = keccak256(to, tokens, token, checkNumber);

         if(sigDigest != sigHash) revert();

         //make sure this signature has never been used
         uint burnedSignature = burnedSignatures[sigDigest];
         burnedSignatures[sigDigest] = 0x2; //invalidated
         if(burnedSignature != 0x0 ) revert();

         return true;
     }


   /*
     Receive approval to spend tokens and perform any action all in one transaction
   */
 function receiveApproval(address from, uint256 tokens, address token, bytes data) public returns (bool) {

   //parse the data:   first byte is for 'action_id'
   byte action_id = data[0];

   if(action_id == 0x1)
   {
     return depositToken(from, token, tokens);
   }

   return false;
   //return false;

 }


}

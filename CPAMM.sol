// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CPAMM2 {
    struct TokenPairs { // it can be TokenPair because it's not bahuvachan aka plural
        bytes4 id;
        IERC20 token0;
        IERC20 token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalSupply;
    }

    // to check balance of user in token pair
    mapping(address => mapping(bytes4 => uint256)) balanceOf;

    // to check token pair's availability
    mapping(bytes4 => bool) isTokenPairAvailable;

    // to get token pair information by its id
    mapping(bytes4 => TokenPairs) public tokenPairsMapping; // getTokenPair
    
    // to store ids of token pair
    bytes4[] TokenPairsIdArr;

    function _mint(
        bytes4 _pid,
        address _to,
        uint256 _amount
    ) private {
        balanceOf[_to][_pid] += _amount;
        tokenPairsMapping[_pid].totalSupply += _amount;
    }

    function _burn(
        bytes4 _pid,
        address _from,
        uint256 _amount
    ) private {
        balanceOf[_from][_pid] -= _amount;
        tokenPairsMapping[_pid].totalSupply -= _amount;
    }

    function _update(
        bytes4 _pid,
        uint256 _reserve0,
        uint256 _reserve1
    ) private {
        tokenPairsMapping[_pid].reserve0 = _reserve0;
        tokenPairsMapping[_pid].reserve1 = _reserve1;
    }

    // to create token pairs and store it in token-pair mapping and token ids in array
    function createTokenPairs(address _token0, address _token1) public {
        // this is an unsafe way to generate id as block.timestamp can be manipulated by the miners
        bytes4 pid = bytes4(keccak256(abi.encodePacked(block.timestamp)));
        TokenPairs memory pair = TokenPairs(
            pid,
            IERC20(_token0),
            IERC20(_token1),
            0,
            0,
            0
        );
        TokenPairsIdArr.push(pid);
        tokenPairsMapping[pid] = pair;
    }

    // to add liquidity
    function addLiquidity(
        bytes4 _pid,
        uint256 _amount0,
        uint256 _amount1
    ) external returns (uint256 shares) {
        require(!isTokenPairAvailable[_pid], "Invalid id");

        // Pull in token0 and token1
        tokenPairsMapping[_pid].token0.transferFrom(
            msg.sender,
            address(this),
            _amount0
        );
        tokenPairsMapping[_pid].token1.transferFrom(
            msg.sender,
            address(this),
            _amount1
        );

        /*
        How much dx, dy to add?

        xy = k
        (x + dx)(y + dy) = k'

        No price change, before and after adding liquidity
        x / y = (x + dx) / (y + dy)

        x(y + dy) = y(x + dx)
        x * dy = y * dx

        x / y = dx / dy
        dy = y / x * dx
        */

        if (
            tokenPairsMapping[_pid].reserve0 > 0 ||
            tokenPairsMapping[_pid].reserve1 > 0
        ) {
            require(
                tokenPairsMapping[_pid].reserve0 * _amount1 ==
                    tokenPairsMapping[_pid].reserve1 * _amount0,
                "dY / dX != Y / X"
            );
        }

        // Mint Shares

        /*
        How much shares to mint?

        f(x, y) = value of liquidity
        We will define f(x, y) = sqrt(xy)

        L0 = f(x, y)
        L1 = f(x + dx, y + dy)
        T = total shares
        s = shares to mint

        Total shares should increase proportional to increase in liquidity
        L1 / L0 = (T + s) / T

        L1 * T = L0 * (T + s)

        (L1 - L0) * T / L0 = s 
        */

        /*
        Claim
        (L1 - L0) / L0 = dx / x = dy / y

        Proof
        --- Equation 1 ---
        (L1 - L0) / L0 = (sqrt((x + dx)(y + dy)) - sqrt(xy)) / sqrt(xy)
        
        dx / dy = x / y so replace dy = dx * y / x

        --- Equation 2 ---
        Equation 1 = (sqrt(xy + 2ydx + dx^2 * y / x) - sqrt(xy)) / sqrt(xy)

        Multiply by sqrt(x) / sqrt(x)
        Equation 2 = (sqrt(x^2y + 2xydx + dx^2 * y) - sqrt(x^2y)) / sqrt(x^2y)
                   = (sqrt(y)(sqrt(x^2 + 2xdx + dx^2) - sqrt(x^2)) / (sqrt(y)sqrt(x^2))
        
        sqrt(y) on top and bottom cancels out

        --- Equation 3 ---
        Equation 2 = (sqrt(x^2 + 2xdx + dx^2) - sqrt(x^2)) / (sqrt(x^2)
        = (sqrt((x + dx)^2) - sqrt(x^2)) / sqrt(x^2)  
        = ((x + dx) - x) / x
        = dx / x

        Since dx / dy = x / y,
        dx / x = dy / y

        Finally
        (L1 - L0) / L0 = dx / x = dy / y
        */

        if (tokenPairsMapping[_pid].totalSupply == 0) {
            shares = _sqrt(_amount0 * _amount1);
        } else {
            shares = _min(
                (_amount0 * tokenPairsMapping[_pid].totalSupply) /
                    tokenPairsMapping[_pid].reserve0,
                (_amount1 * tokenPairsMapping[_pid].totalSupply) /
                    tokenPairsMapping[_pid].reserve1
            );
        }

        require(shares > 0, "shares = 0");
        _mint(_pid, msg.sender, shares);

        // Update reserves
        _update(
            _pid,
            tokenPairsMapping[_pid].token0.balanceOf(address(this)),
            tokenPairsMapping[_pid].token1.balanceOf(address(this))
        );
    }

    function removeLiquidity(bytes4 _pid, uint256 _shares)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(!isTokenPairAvailable[_pid], "Invalid id");

        // Calculate amount0 and amout1 to windraw
        /*
        Claim
        dx, dy = amount of liquidity to remove
        dx = s / T * x
        dy = s / T * y

        Proof
        Let's find dx, dy such that
        v / L = s / T
        
        where
        v = f(dx, dy) = sqrt(dxdy)
        L = total liquidity = sqrt(xy)
        s = shares
        T = total supply

        --- Equation 1 ---
        v = s / T * L
        sqrt(dxdy) = s / T * sqrt(xy)

        Amount of liquidity to remove must not change price so 
        dx / dy = x / y

        replace dy = dx * y / x
        sqrt(dxdy) = sqrt(dx * dx * y / x) = dx * sqrt(y / x)

        Divide both sides of Equation 1 with sqrt(y / x)
        dx = s / T * sqrt(xy) / sqrt(y / x)
           = s / T * sqrt(x^2) = s / T * x

        Likewise
        dy = s / T * y
        */

        // bal0 >= reserve0
        // bal1 >= reserve1

        uint256 bal0 = tokenPairsMapping[_pid].token0.balanceOf(address(this));
        uint256 bal1 = tokenPairsMapping[_pid].token1.balanceOf(address(this));

        amount0 = (_shares * bal0) / tokenPairsMapping[_pid].totalSupply;
        amount1 = (_shares * bal1) / tokenPairsMapping[_pid].totalSupply;

        require(
            amount0 > 0 && amount1 > 0,
            "Amount should be greater than zero"
        );

        // Burn shares
        _burn(_pid, msg.sender, _shares);

        // Update reserves
        _update(_pid, bal0 - amount0, bal1 - amount1);

        // Transfer tokens to msg.sender
        tokenPairsMapping[_pid].token0.transfer(msg.sender, amount0);
        tokenPairsMapping[_pid].token1.transfer(msg.sender, amount1);
    }

    function swapTokens(
        bytes4 _pid,
        address _tokenIn,
        uint256 _amountIn
    ) external returns (uint256 amountOut) {
        require(!isTokenPairAvailable[_pid], "Invalid id");
        require(
            _tokenIn == address(tokenPairsMapping[_pid].token0) ||
                _tokenIn == address(tokenPairsMapping[_pid].token1),
            "Invalid token"
        );
        
        require(_amountIn > 0, "Amount should be greater than zero");

        // Pull in token in
        bool isToken0 = _tokenIn == address(tokenPairsMapping[_pid].token0);
        (
            IERC20 tokenIn,
            IERC20 tokenOut,
            uint256 reserveIn,
            uint256 reserveOut
        ) = isToken0
                ? (
                    tokenPairsMapping[_pid].token0,
                    tokenPairsMapping[_pid].token1,
                    tokenPairsMapping[_pid].reserve0,
                    tokenPairsMapping[_pid].reserve1
                )
                : (
                    tokenPairsMapping[_pid].token1,
                    tokenPairsMapping[_pid].token0,
                    tokenPairsMapping[_pid].reserve1,
                    tokenPairsMapping[_pid].reserve0
                );

        tokenIn.transferFrom(msg.sender, address(this), _amountIn);

        // Calculate token out (include fees), fee 0.3%
        /*
        How much dy for dx?

        xy = k
        (x + dx)(y - dy) = k
        y - dy = k / (x + dx)
        y - k / (x + dx) = dy
        y - xy / (x + dx) = dy
        (yx + ydx - xy) / (x + dx) = dy
        ydx / (x + dx) = dy
        */
        // 0.3% fee

        uint256 amountInWithFee = (_amountIn * 997) / 1000;

        amountOut =
            (reserveOut * amountInWithFee) /
            (reserveIn + amountInWithFee);

        // Transfer token out to msg.sender
        tokenOut.transfer(msg.sender, amountOut);

        // Update the reserves
        _update(
            _pid,
            tokenPairsMapping[_pid].token0.balanceOf(address(this)),
            tokenPairsMapping[_pid].token1.balanceOf(address(this))
        );
    }

    function getTokenPairs() public view returns (bytes4[] memory) {
        return TokenPairsIdArr;
    }

    function getBalance(bytes4 _pid, address _userAddress)
        public
        view
        returns (uint256)
    {
        return balanceOf[_userAddress][_pid];
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CUToken.sol";

contract GovernanceContract is ReentrancyGuard, Ownable, Pausable {
    CampusCoin public campusCoin;
    
    // Configuración de governance
    uint256 public constant PROPOSAL_CREATION_FEE = 1000 * 10**18; // 1000 CC
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant EXECUTION_DELAY = 1 days;
    uint256 public quorumPercentage = 10; // 10% del suministro circulante
    
    // Estructura de propuesta
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool cancelled;
        mapping(address => bool) hasVoted;
        mapping(address => uint256) votes;
    }
    
    // Propuestas
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    
    // Estadísticas
    uint256 public totalProposals;
    uint256 public totalVotes;
    uint256 public totalProposalFees;
    
    // Eventos
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 startTime,
        uint256 endTime
    );
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        bool support,
        uint256 votes
    );
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor
    );
    event ProposalCancelled(
        uint256 indexed proposalId,
        address indexed canceller
    );
    
    constructor(address _campusCoin) Ownable(msg.sender) {
        require(_campusCoin != address(0), "Invalid token address");
        campusCoin = CampusCoin(_campusCoin);
    }
    
    // Crear propuesta
    function createProposal(
        string memory title,
        string memory description
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(bytes(title).length > 0, "Title required");
        require(bytes(description).length > 0, "Description required");
        require(campusCoin.balanceOf(msg.sender) >= PROPOSAL_CREATION_FEE, "Insufficient balance");
        
        // Transferir fee de creación
        require(
            campusCoin.transferFrom(msg.sender, address(this), PROPOSAL_CREATION_FEE),
            "Fee transfer failed"
        );
        
        uint256 proposalId = proposalCount++;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + VOTING_PERIOD;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.startTime = startTime;
        proposal.endTime = endTime;
        proposal.forVotes = 0;
        proposal.againstVotes = 0;
        proposal.executed = false;
        proposal.cancelled = false;
        
        totalProposals++;
        totalProposalFees += PROPOSAL_CREATION_FEE;
        
        emit ProposalCreated(proposalId, msg.sender, title, startTime, endTime);
        return proposalId;
    }
    
    // Votar en propuesta
    function vote(uint256 proposalId, bool support) external nonReentrant {
        require(proposalId < proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.startTime, "Voting not started");
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(!proposal.executed, "Proposal executed");
        require(!proposal.cancelled, "Proposal cancelled");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        
        uint256 votingPower = campusCoin.balanceOf(msg.sender);
        require(votingPower > 0, "No voting power");
        
        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = votingPower;
        
        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }
        
        totalVotes += votingPower;
        
        emit VoteCast(msg.sender, proposalId, support, votingPower);
    }
    
    // Ejecutar propuesta
    function executeProposal(uint256 proposalId) external nonReentrant {
        require(proposalId < proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Proposal cancelled");
        
        uint256 totalVotes_ = proposal.forVotes + proposal.againstVotes;
        uint256 quorumRequired = (campusCoin.totalSupply() * quorumPercentage) / 100;
        
        require(totalVotes_ >= quorumRequired, "Quorum not met");
        require(proposal.forVotes > proposal.againstVotes, "Proposal rejected");
        
        proposal.executed = true;
        
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    // Cancelar propuesta (solo proposer o owner)
    function cancelProposal(uint256 proposalId) external {
        require(proposalId < proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || msg.sender == owner(),
            "Not authorized"
        );
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Already cancelled");
        
        proposal.cancelled = true;
        
        emit ProposalCancelled(proposalId, msg.sender);
    }
    
    // Obtener propuesta
    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        string memory title,
        string memory description,
        uint256 startTime,
        uint256 endTime,
        uint256 forVotes,
        uint256 againstVotes,
        bool executed,
        bool cancelled
    ) {
        require(proposalId < proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.startTime,
            proposal.endTime,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.executed,
            proposal.cancelled
        );
    }
    
    // Obtener propuestas por estado
    function getProposalsByStatus(bool active) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < proposalCount; i++) {
            Proposal storage proposal = proposals[i];
            bool isActive = block.timestamp >= proposal.startTime && 
                           block.timestamp <= proposal.endTime && 
                           !proposal.executed && 
                           !proposal.cancelled;
            
            if (isActive == active) {
                count++;
            }
        }
        
        uint256[] memory result = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < proposalCount; i++) {
            Proposal storage proposal = proposals[i];
            bool isActive = block.timestamp >= proposal.startTime && 
                           block.timestamp <= proposal.endTime && 
                           !proposal.executed && 
                           !proposal.cancelled;
            
            if (isActive == active) {
                result[index] = i;
                index++;
            }
        }
        
        return result;
    }
    
    // Obtener estadísticas de governance
    function getGovernanceStats() external view returns (
        uint256 totalProposals_,
        uint256 totalVotes_,
        uint256 totalFees_,
        uint256 quorumRequired_,
        uint256 votingPower_
    ) {
        totalProposals_ = totalProposals;
        totalVotes_ = totalVotes;
        totalFees_ = totalProposalFees;
        quorumRequired_ = (campusCoin.totalSupply() * quorumPercentage) / 100;
        votingPower_ = campusCoin.balanceOf(msg.sender);
    }
    
    // Verificar si puede votar
    function canVote(uint256 proposalId, address voter) external view returns (bool, string memory) {
        if (proposalId >= proposalCount) {
            return (false, "Invalid proposal ID");
        }
        
        Proposal storage proposal = proposals[proposalId];
        
        if (block.timestamp < proposal.startTime) {
            return (false, "Voting not started");
        }
        
        if (block.timestamp > proposal.endTime) {
            return (false, "Voting ended");
        }
        
        if (proposal.executed) {
            return (false, "Proposal executed");
        }
        
        if (proposal.cancelled) {
            return (false, "Proposal cancelled");
        }
        
        if (proposal.hasVoted[voter]) {
            return (false, "Already voted");
        }
        
        if (campusCoin.balanceOf(voter) == 0) {
            return (false, "No voting power");
        }
        
        return (true, "Can vote");
    }
    
    // Actualizar quorum (solo owner)
    function setQuorumPercentage(uint256 newPercentage) external onlyOwner {
        require(newPercentage > 0 && newPercentage <= 50, "Invalid percentage");
        quorumPercentage = newPercentage;
    }
    
    // Función de pausa de emergencia
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Función de emergencia para recuperar tokens
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= campusCoin.balanceOf(address(this)), "Insufficient balance");
        require(campusCoin.transfer(owner(), amount), "Transfer failed");
    }
}

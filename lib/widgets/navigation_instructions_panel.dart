import 'package:flutter/material.dart';
import '../models/graphhopper_response.dart';

class NavigationInstructionsPanel extends StatefulWidget {
  final Path routePath;
  final VoidCallback? onClose;
  final int currentInstructionIndex;

  const NavigationInstructionsPanel({
    super.key,
    required this.routePath,
    this.onClose,
    this.currentInstructionIndex = 1,
  });

  @override
  State<NavigationInstructionsPanel> createState() =>
      _NavigationInstructionsPanelState();
}

class _NavigationInstructionsPanelState
    extends State<NavigationInstructionsPanel> {
  bool _isExpanded = false;
  int? _selectedInstructionIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [_buildHeader(), if (_isExpanded) _buildInstructionsList()],
      ),
    );
  }

  Widget _buildHeader() {
    // Prikazujemo trenutnu aktivnu instrukciju (ne prvu)
    final currentInstruction =
        widget.currentInstructionIndex < widget.routePath.instructions.length
        ? widget.routePath.instructions[widget.currentInstructionIndex]
        : widget.routePath.instructions.last;

    return GestureDetector(
      onTap: () {
        setState(() => _isExpanded = !_isExpanded);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.blue[700],
          borderRadius: _isExpanded
              ? const BorderRadius.vertical(top: Radius.circular(12))
              : const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(
          children: [
            Icon(
              _isExpanded ? Icons.expand_more : Icons.expand_less,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📍 ${widget.routePath.getDistanceText()} • ⏱️ ${widget.routePath.getTimeText()}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (!_isExpanded)
                    Row(
                      children: [
                        Text(
                          currentInstruction.getInstructionIcon(),
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            currentInstruction.text,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (widget.onClose != null)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: widget.onClose,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionsList() {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.12, // Još kompaktnije
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.routePath.instructions.length,
        itemBuilder: (context, index) {
          final instruction = widget.routePath.instructions[index];
          final isSelected = _selectedInstructionIndex == index;
          final isCurrentInstruction = index == widget.currentInstructionIndex;
          final isLastInstruction =
              index == widget.routePath.instructions.length - 1;
          final isPassed = index < widget.currentInstructionIndex;

          // Preskačemo prvu instrukciju u listi (index 0)
          if (index == 0) {
            return const SizedBox.shrink();
          }

          return InkWell(
            onTap: () {
              setState(() {
                _selectedInstructionIndex = isSelected ? null : index;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isCurrentInstruction
                    ? Colors.orange[100]
                    : (isSelected
                          ? Colors.blue[50]
                          : (isPassed ? Colors.grey[100] : Colors.transparent)),
                border: Border(
                  left: isCurrentInstruction
                      ? BorderSide(color: Colors.orange[700]!, width: 4)
                      : BorderSide.none,
                  bottom: BorderSide(color: Colors.grey[300]!, width: 1),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: isLastInstruction
                          ? Colors.green[100]
                          : (isCurrentInstruction
                                ? Colors.orange[100]
                                : (isPassed
                                      ? Colors.grey[300]
                                      : Colors.blue[100])),
                      shape: BoxShape.circle,
                      border: isCurrentInstruction
                          ? Border.all(color: Colors.orange[700]!, width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        instruction.getInstructionIcon(),
                        style: TextStyle(
                          fontSize: 13,
                          color: isPassed ? Colors.grey[600] : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                instruction.text,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isCurrentInstruction
                                      ? FontWeight.bold
                                      : (isSelected
                                            ? FontWeight.w600
                                            : FontWeight.normal),
                                  color: isPassed
                                      ? Colors.grey[600]
                                      : Colors.black87,
                                  decoration: isPassed
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                            if (isCurrentInstruction)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange[700],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  'TRENUTNO',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            if (instruction.distance > 0) ...[
                              Icon(
                                Icons.straighten,
                                size: 10,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(width: 2),
                              Text(
                                instruction.getDistanceText(),
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (instruction.time > 0) ...[
                              Icon(
                                Icons.access_time,
                                size: 10,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '${(instruction.time / 60000).round()} min',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isLastInstruction)
                    const Icon(Icons.flag, color: Colors.green),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

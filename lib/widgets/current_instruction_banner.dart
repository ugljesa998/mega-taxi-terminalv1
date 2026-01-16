import 'package:flutter/material.dart';
import '../models/graphhopper_response.dart';

class CurrentInstructionBanner extends StatelessWidget {
  final Instruction instruction;
  final Instruction? nextInstruction;

  const CurrentInstructionBanner({
    super.key,
    required this.instruction,
    this.nextInstruction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green[600],
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Distanca - VELIKO
          if (instruction.distance > 0)
            Text(
              instruction.getDistanceText().replaceAll(' ', ''),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          const SizedBox(width: 12),
          // Ikonica akcije
          Text(
            instruction.getInstructionIcon(),
            style: const TextStyle(fontSize: 24),
          ),
          const SizedBox(width: 8),
          // Tekst instrukcije
          Expanded(
            child: Text(
              instruction.text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
